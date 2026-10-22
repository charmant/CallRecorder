import AudioToolbox
import CoreAudio
import Foundation
import Synchronization

/// Recording of one call. The process tap (them) and the microphone (you) are combined into one private
/// aggregate device: both streams arrive in a single IOProc with a shared clock, so the tracks
/// are frame-aligned without separate synchronization, and the aggregate itself compensates for tap drift.
final class CaptureSession: @unchecked Sendable {
    struct Live {
        var localPeak: Float = 0
        var remotePeak: Float = 0
        var localSilence: TimeInterval = 0
        var remoteSilence: TimeInterval = 0
        var warning: String?
    }

    let source: CallSource
    let folder: URL
    let microphoneName: String
    private let processObjectIDs: [AudioObjectID]
    private let microphone: AudioHardwareDevice
    private let system = AudioHardwareSystem.shared
    private let events: DiagnosticLog
    private let info: Mutex<SessionInfo>
    private let warning = Mutex<String?>(nil)
    private let writeError = Mutex<String?>(nil)
    private let stats = IOStats()

    private var tap: AudioHardwareTap?
    private var aggregate: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var local: TrackWriter?
    private var remote: TrackWriter?
    private var writerThread: Thread?
    private let stopRequested = Atomic<Bool>(false)
    private let writerDone = DispatchSemaphore(value: 0)
    private let listenerQueue = DispatchQueue(label: "CallRecorder.listeners")
    private var listeners: [Listener] = []

    private struct Listener {
        let object: AudioObjectID
        let address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    init(source: CallSource, processes: [AudioProcessInfo], microphone: AudioHardwareDevice, folder: URL) {
        self.source = source
        self.folder = folder
        self.microphone = microphone
        self.microphoneName = (try? microphone.name) ?? "?"
        processObjectIDs = processes.map(\.objectID)
        events = DiagnosticLog(url: folder.appending(path: "events.log"))
        info = Mutex(SessionInfo(source: source.title, startedAt: Date(), processes: processes.map(\.summary)))
    }

    func start() throws {
        do {
            try setUp()
        } catch {
            event("start failed: \(error.localizedDescription)")
            tearDown()
            writeInfo()
            throw error
        }
    }

    struct SaveResult {
        let duration: TimeInterval
        let problems: [String]
    }

    /// Stops recording, finalizes the files, session.json and the combined conversation.m4a.
    /// Mixdown can take seconds on a long recording — don't call it from the main thread.
    func finish(reason: String) -> SaveResult {
        tearDown()
        event("stop: \(reason)")

        var files = ["local.caf", "remote.caf", "events.log", "session.json"]
        var problems: [String] = []
        if stats.callbacks.load(ordering: .relaxed) == 0 {
            problems.append("the audio device delivered no buffers")
        }
        if let local, let remote, max(local.framesWritten, remote.framesWritten) > 0 {
            do {
                try Mixdown.run(local: local.url, remote: remote.url, output: folder.appending(path: "conversation.m4a"))
                files.append("conversation.m4a")
                if Waveform.build(in: folder) != nil { files.append("waveform.json") }
            } catch {
                problems.append("mixdown failed: \(error.localizedDescription)")
            }
        }
        let diskError = writeError.withLock { $0 }
        if let diskError { problems.append("disk write error: \(diskError)") }
        if let local, local.framesWritten > 0, !local.everHadSound {
            problems.append("\"you\" track is completely silent")
        }
        if let remote, remote.framesWritten > 0, !remote.everHadSound {
            problems.append("\"them\" track is completely silent: no system audio access or the wrong process was tapped")
        }
        let inserted = (local?.silenceInsertedFrames ?? 0) + (remote?.silenceInsertedFrames ?? 0)
        if inserted > 0 { problems.append("silence inserted for \(inserted) lost frames") }
        problems.forEach { event("issue: \($0)") }

        let callbacks = stats.callbacks.load(ordering: .relaxed)
        let layout = stats.firstCallbackLayout
        info.withLock { info in
            info.endedAt = Date()
            info.stopReason = reason
            info.completed = diskError == nil && callbacks > 0
            info.ioCallbacks = callbacks
            info.firstCallbackBuffers = layout
            if let local { info.local = local.summary(file: "local.caf") }
            if let remote { info.remote = remote.summary(file: "remote.caf") }
            info.problems = problems
            info.files = files
        }
        writeInfo()

        return SaveResult(duration: Double(remote?.framesWritten ?? 0) / (remote?.sampleRate ?? 1), problems: problems)
    }

    func live() -> Live {
        Live(
            localPeak: local?.peak ?? 0,
            remotePeak: remote?.peak ?? 0,
            localSilence: local?.secondsSinceSound ?? 0,
            remoteSilence: remote?.secondsSinceSound ?? 0,
            warning: writeError.withLock { $0 } ?? warning.withLock { $0 }
        )
    }

    func event(_ text: String, isWarning: Bool = false) {
        events.write(text)
        let stamp = Self.timeFormatter.string(from: Date())
        info.withLock { $0.events.append("\(stamp) \(text)") }
        if isWarning { warning.withLock { $0 = text } }
    }

    // MARK: - Setup

    private func setUp() throws {
        // 1. Tap on the call's processes. unmuted: audio keeps playing to the headphones.
        let description: CATapDescription
        if source == .systemWide {
            let own = (try? system.process(for: getpid())).map { [$0.id] } ?? []
            description = CATapDescription(stereoGlobalTapButExcludeProcesses: own)
        } else {
            description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        }
        description.uuid = UUID()
        description.name = "CallRecorder"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        guard let tap = try system.makeProcessTap(description: description) else {
            throw RecorderError("Core Audio didn't create the process tap")
        }
        self.tap = tap

        // 2. Aggregate: the microphone sets the clock, the tap adapts to it.
        // We don't add the output device to the aggregate: AirPods have an input, and the aggregate
        // would enable their microphone even if the call goes through the Mac's microphone.
        let micUID = try microphone.uid
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "CallRecorder",
            kAudioAggregateDeviceUIDKey: "CallRecorder-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceIsStackedKey: 0,
            // Not 1: with autostart, start waits for the first sound in the tap, and your voice isn't recorded
            // while the other side is silent (or at all, if the app isn't playing anything yet).
            kAudioAggregateDeviceTapAutoStartKey: 0,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: micUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: 1,
            ]],
        ]
        guard let aggregate = try system.makeAggregateDevice(description: composition) else {
            throw RecorderError("Core Audio didn't create the aggregate device")
        }
        self.aggregate = aggregate

        // 3. Aggregate input buffers: microphone streams first, then the tap.
        let inputChannels = try aggregate.inputStreamConfiguration.map { Int($0.mNumberChannels) }
        let micStreams = try microphone.inputStreamConfiguration.count
        guard micStreams > 0, inputChannels.count > micStreams else {
            throw RecorderError("Unexpected aggregate inputs: \(inputChannels), microphone streams: \(micStreams)")
        }
        let micIndex = 0
        let tapIndex = micStreams
        let micChannels = inputChannels[micIndex]
        let tapChannels = inputChannels[tapIndex]
        let sampleRate = try aggregate.nominalSampleRate

        let local = try TrackWriter(url: folder.appending(path: "local.caf"), channels: micChannels, sampleRate: sampleRate)
        let remote = try TrackWriter(url: folder.appending(path: "remote.caf"), channels: tapChannels, sampleRate: sampleRate)
        self.local = local
        self.remote = remote

        let outputName = (try? system.defaultOutputDevice).flatMap { try? $0.name } ?? "?"
        let tapFormat = (try? tap.format.summary) ?? "?"
        info.withLock { info in
            info.microphone = "\(microphoneName) [\(micUID)]"
            info.outputDevice = outputName
            info.sampleRate = sampleRate
            info.tapFormat = tapFormat
            info.aggregateInputChannels = inputChannels
            info.micBufferIndex = micIndex
            info.tapBufferIndex = tapIndex
        }

        // 4. IOProc: only copying into the ring buffers — no allocations, locks or disk.
        let localRing = local.ring
        let remoteRing = remote.ring
        let stats = self.stats
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate.id, nil) { _, inputData, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            stats.note(buffers, hostTime: inputTime.pointee.mHostTime)
            let frames = max(
                Self.frameCount(buffers, micIndex, channels: micChannels),
                Self.frameCount(buffers, tapIndex, channels: tapChannels)
            )
            Self.push(buffers, micIndex, channels: micChannels, frames: frames, into: localRing)
            Self.push(buffers, tapIndex, channels: tapChannels, frames: frames, into: remoteRing)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        ioProcID = procID

        // 5. Watch for sample rate changes, device disconnects and overloads.
        listen(aggregate.id, kAudioDevicePropertyNominalSampleRate, isWarning: true) {
            "aggregate sample rate changed to \((try? aggregate.nominalSampleRate) ?? 0) Hz — audio after this point may be distorted"
        }
        listen(aggregate.id, kAudioDeviceProcessorOverload) { "I/O overload (possible click)" }
        listen(microphone.id, kAudioDevicePropertyDeviceIsAlive, isWarning: true) { "microphone disconnected" }
        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        listen(systemObject, kAudioHardwarePropertyDefaultInputDevice) { [system] in
            "system input changed: \((try? system.defaultInputDevice).flatMap { try? $0.name } ?? "?")"
        }
        listen(systemObject, kAudioHardwarePropertyDefaultOutputDevice) { [system] in
            "system output changed: \((try? system.defaultOutputDevice).flatMap { try? $0.name } ?? "?")"
        }

        // 6. Disk writer thread and start.
        let thread = Thread { [self] in writerLoop() }
        thread.name = "CallRecorder.writer"
        thread.qualityOfService = .userInitiated
        writerThread = thread
        thread.start()

        try aggregate.start(IOProcID: procID)
        event("start: \(source.title), microphone \(microphoneName), \(Int(sampleRate)) Hz, inputs \(inputChannels), tap \(tapFormat)")
        writeInfo()
    }

    private func tearDown() {
        if let aggregate, let ioProcID {
            try? aggregate.stop(IOProcID: ioProcID)
            AudioDeviceDestroyIOProcID(aggregate.id, ioProcID)
        }
        ioProcID = nil
        if writerThread != nil {
            stopRequested.store(true, ordering: .releasing)
            writerDone.wait()
            writerThread = nil
        }
        local?.close()
        remote?.close()
        for listener in listeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(listener.object, &address, listenerQueue, listener.block)
        }
        listeners.removeAll()
        if let aggregate { try? system.destroyAggregateDevice(aggregate) }
        aggregate = nil
        if let tap { try? system.destroyProcessTap(tap) }
        tap = nil
    }

    // MARK: - Writer thread

    private func writerLoop() {
        while !stopRequested.load(ordering: .acquiring) {
            drain()
            Thread.sleep(forTimeInterval: 0.05)
        }
        drain()
        writerDone.signal()
    }

    private func drain() {
        for track in [local, remote] {
            guard let track else { continue }
            do {
                try track.drain()
            } catch {
                writeError.withLock { if $0 == nil { $0 = error.localizedDescription } }
            }
        }
    }

    // MARK: - Helpers

    private static func frameCount(_ buffers: UnsafeMutableAudioBufferListPointer, _ index: Int, channels: Int) -> Int {
        guard index < buffers.count, channels > 0 else { return 0 }
        return Int(buffers[index].mDataByteSize) / (channels * MemoryLayout<Float>.size)
    }

    /// Puts the buffer into the track; if there is none, silence of the same length, so the tracks stay aligned.
    private static func push(_ buffers: UnsafeMutableAudioBufferListPointer, _ index: Int, channels: Int, frames: Int, into ring: SampleRingBuffer) {
        let samples = frames * channels
        if index < buffers.count, let data = buffers[index].mData,
           Int(buffers[index].mDataByteSize) >= samples * MemoryLayout<Float>.size {
            ring.write(data.assumingMemoryBound(to: Float.self), count: samples)
        } else {
            ring.writeSilence(count: samples)
        }
    }

    private func listen(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, isWarning: Bool = false, _ describe: @escaping () -> String) {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.event(describe(), isWarning: isWarning)
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, listenerQueue, block) == noErr {
            listeners.append(Listener(object: object, address: address, block: block))
        }
    }

    private func writeInfo() {
        let snapshot = info.withLock { $0 }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: folder.appending(path: "session.json"), options: .atomic)
        }
    }
}

/// Counters from the IOProc. We remember the buffer layout of the first call for session.json:
/// it shows that the aggregate delivered exactly the streams we expected.
final class IOStats: @unchecked Sendable {
    let callbacks = Atomic<Int>(0)
    let firstHostTime = Atomic<UInt64>(0)
    private let layoutCaptured = Atomic<Bool>(false)
    private let layout = UnsafeMutablePointer<UInt32>.allocate(capacity: 17) // [count, (channels, bytes) × 8]

    deinit {
        layout.deallocate()
    }

    /// Called from the IOProc.
    func note(_ buffers: UnsafeMutableAudioBufferListPointer, hostTime: UInt64) {
        guard callbacks.wrappingAdd(1, ordering: .relaxed).oldValue == 0 else { return }
        firstHostTime.store(hostTime, ordering: .relaxed)
        let count = min(buffers.count, 8)
        layout[0] = UInt32(count)
        for index in 0..<count {
            layout[1 + 2 * index] = buffers[index].mNumberChannels
            layout[2 + 2 * index] = buffers[index].mDataByteSize
        }
        layoutCaptured.store(true, ordering: .releasing)
    }

    var firstCallbackLayout: String {
        guard layoutCaptured.load(ordering: .acquiring) else { return "no data" }
        return (0..<Int(layout[0]))
            .map { "#\($0): \(layout[1 + 2 * $0]) ch, \(layout[2 + 2 * $0]) B" }
            .joined(separator: "; ")
    }
}
