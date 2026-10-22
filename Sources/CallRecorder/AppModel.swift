import AppKit
import CoreAudio
import Observation

struct MicrophoneOption: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Message in the panel: save result or error.
struct StatusMessage: Equatable {
    enum Kind {
        case success, warning, error
    }

    let kind: Kind
    let title: String
    var details: [String] = []
}

@MainActor
@Observable
final class AppModel {
    enum Phase {
        case idle, recording, finishing
    }

    static let recordingsFolder = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Calls", directoryHint: .isDirectory)

    private(set) var phase: Phase = .idle
    private(set) var activeCall: CallSource?
    private(set) var recordingSource: CallSource?
    private(set) var recordingMicName = ""
    private(set) var elapsedSeconds = 0
    /// Levels 0…1, rounded to 1/40: meters redraw only when the difference is visible.
    private(set) var localLevel: Float = 0
    private(set) var remoteLevel: Float = 0
    private(set) var localSilent = false
    private(set) var remoteSilent = false
    /// How many seconds the other party has been inaudible — only once it becomes suspicious (20 s and up).
    private(set) var remoteSilentSeconds: Int?
    private(set) var sessionWarning: String?
    private(set) var autoStopIn: Int?
    private(set) var status: StatusMessage?
    private(set) var micPermission: PermissionState = .unknown
    private(set) var systemAudioPermission: PermissionState = .unknown
    private(set) var microphones: [MicrophoneOption] = []
    private(set) var defaultMicName = "—"
    private(set) var activeProcesses: [AudioProcessInfo] = []
    private(set) var recordings: [Recording] = []
    let playback = Playback()

    /// Empty string means the system default microphone.
    var selectedMicUID = UserDefaults.standard.string(forKey: "micUID") ?? "" {
        didSet { UserDefaults.standard.set(selectedMicUID, forKey: "micUID") }
    }

    @ObservationIgnored private let diagnostics: DiagnosticLog
    @ObservationIgnored private let monitor: ProcessMonitor
    @ObservationIgnored private var session: CaptureSession?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var sawCallDuringRecording = false
    @ObservationIgnored private var callEndedAt: Date?

    /// How many seconds the call app must stay off the microphone before recording stops.
    private let autoStopDelay: TimeInterval = 3

    var elapsedText: String { formatDuration(TimeInterval(elapsedSeconds)) }
    var permissionsDenied: Bool { micPermission == .denied || systemAudioPermission == .denied }
    /// Recording is available only when a call is visible: the source is always detected automatically.
    var canRecord: Bool { phase == .idle && activeCall != nil && !permissionsDenied }
    var recentRecordings: [Recording] { Array(recordings.prefix(5)) }

    init() {
        diagnostics = DiagnosticLog(url: Self.recordingsFolder.appending(path: "_diagnostics/audio-processes.log"))
        monitor = ProcessMonitor(log: diagnostics)
        monitor.onChange = { [weak self] processes, changes in
            self?.processesChanged(processes, changes)
        }
        diagnostics.write("=== CallRecorder started, macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        monitor.start()
        processesChanged(monitor.processes, [])
        refreshPermissions()
        refreshMicrophones()
        reloadHistory()
        if let state = PreviewHarness.state {
            applyPreview(state)
            PreviewHarness.show(model: self, log: diagnostics)
        } else {
            runSelfTestIfRequested()
        }
    }

    // MARK: - Recording

    func startRecording(_ requested: CallSource? = nil) async {
        guard phase == .idle else { return }
        status = nil
        playback.stop()
        guard await ensurePermissions() else { return }

        monitor.poll()
        let processes = monitor.processes
        guard let source = requested ?? CallSource.activeCall(in: processes) else {
            status = StatusMessage(kind: .error, title: "No FaceTime or Telegram call detected")
            return
        }
        let targets = processes.filter { source.matches($0) }
        if source != .systemWide, targets.isEmpty {
            status = StatusMessage(kind: .error, title: "\(source.title) isn't using audio right now")
            return
        }

        do {
            let microphone = try resolveMicrophone()
            let folder = try makeSessionFolder(source)
            let session = CaptureSession(source: source, processes: targets, microphone: microphone, folder: folder)
            try session.start()
            self.session = session
            phase = .recording
            recordingSource = source
            recordingMicName = session.microphoneName
            startedAt = Date()
            elapsedSeconds = 0
            sessionWarning = nil
            autoStopIn = nil
            callEndedAt = nil
            sawCallDuringRecording = targets.contains { $0.isRunningInput }
            startTicker()
            diagnostics.write("● recording: \(source.title) → \(folder.path)")
        } catch {
            status = StatusMessage(kind: .error, title: "Couldn't start recording", details: [error.localizedDescription])
            diagnostics.write("✗ start failed: \(error.localizedDescription)")
        }
    }

    func stopRecording(reason: String) async {
        guard phase == .recording, let session else { return }
        phase = .finishing
        ticker?.invalidate()
        ticker = nil
        autoStopIn = nil
        callEndedAt = nil
        diagnostics.write("■ stop: \(reason)")
        let result = await Task.detached(priority: .userInitiated) { session.finish(reason: reason) }.value
        self.session = nil
        phase = .idle
        recordingSource = nil
        localLevel = 0
        remoteLevel = 0
        remoteSilentSeconds = nil
        sessionWarning = nil
        let duration = formatDuration(result.duration)
        status = result.problems.isEmpty
            ? StatusMessage(kind: .success, title: "Saved · \(duration)")
            : StatusMessage(kind: .warning, title: "Saved · \(duration), with issues", details: result.problems)
        diagnostics.write("  \(status?.title ?? "") \(result.problems.joined(separator: "; "))")
        reloadHistory()
    }

    // MARK: - History

    func reloadHistory() {
        guard PreviewHarness.state == nil else { return }
        recordings = RecordingHistory.load(from: Self.recordingsFolder)
    }

    func reveal(_ recording: Recording) {
        NSWorkspace.shared.activateFileViewerSelecting([recording.folder])
    }

    /// To the Trash, not deleted for good: the recording can be restored from Finder.
    func moveToTrash(_ recording: Recording) {
        if playback.isCurrent(recording) { playback.stop() }
        do {
            try FileManager.default.trashItem(at: recording.folder, resultingItemURL: nil)
        } catch {
            status = StatusMessage(kind: .error, title: "Couldn't move to Trash", details: [error.localizedDescription])
        }
        reloadHistory()
    }

    // MARK: - State

    func refreshPermissions() {
        guard PreviewHarness.state == nil else { return }
        micPermission = Permissions.microphone
        systemAudioPermission = Permissions.systemAudio
    }

    func refreshMicrophones() {
        let system = AudioHardwareSystem.shared
        let devices = (try? system.devices) ?? []
        microphones = devices.compactMap { device in
            guard let uid = try? device.uid, !uid.hasPrefix("CallRecorder"),
                  let inputs = try? device.inputStreamConfiguration, !inputs.isEmpty
            else { return nil }
            return MicrophoneOption(uid: uid, name: (try? device.name) ?? uid)
        }
        if PreviewHarness.state == nil {
            defaultMicName = (try? system.defaultInputDevice).flatMap { try? $0.name } ?? "—"
        }
    }

    private func processesChanged(_ processes: [AudioProcessInfo], _ changes: [String]) {
        guard PreviewHarness.state == nil else { return }
        activeProcesses = processes.filter { $0.isRunningInput || $0.isRunningOutput }
        activeCall = CallSource.activeCall(in: processes)
        guard phase == .recording, let session, let source = recordingSource else { return }
        if !changes.isEmpty {
            session.event("processes: " + changes.joined(separator: " | "))
        }
        guard source != .systemWide else { return }
        let inCall = processes.contains { source.matches($0) && $0.isRunningInput }
        if inCall {
            sawCallDuringRecording = true
            callEndedAt = nil
        } else if sawCallDuringRecording, callEndedAt == nil {
            callEndedAt = Date()
            session.event("\(source.title) released the microphone — the call seems to have ended")
        }
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        guard phase == .recording, let session else { return }
        let live = session.live()
        update(\.elapsedSeconds, Int(Date().timeIntervalSince(startedAt)))
        update(\.localLevel, Self.quantize(live.localPeak))
        update(\.remoteLevel, Self.quantize(live.remotePeak))
        update(\.localSilent, live.localSilence > 5)
        update(\.remoteSilent, live.remoteSilence > 5)
        update(\.remoteSilentSeconds, live.remoteSilence >= 20 ? Int(live.remoteSilence) : nil)
        update(\.sessionWarning, live.warning)

        guard let callEndedAt else {
            update(\.autoStopIn, nil)
            return
        }
        let left = autoStopDelay - Date().timeIntervalSince(callEndedAt)
        if left <= 0 {
            self.callEndedAt = nil
            Task { await stopRecording(reason: "call ended") }
        } else {
            update(\.autoStopIn, Int(left.rounded(.up)))
        }
    }

    /// Assigns only if the value changed: otherwise Observation redraws the panel for nothing.
    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private static func quantize(_ peak: Float) -> Float {
        (meterValue(peak: peak) * 40).rounded() / 40
    }

    // MARK: - Helpers

    private func ensurePermissions() async -> Bool {
        if Permissions.microphone == .unknown { _ = await Permissions.requestMicrophone() }
        if Permissions.systemAudio == .unknown { _ = await Permissions.requestSystemAudio() }
        refreshPermissions()
        if micPermission == .denied {
            status = StatusMessage(kind: .error, title: "No microphone access",
                                   details: ["System Settings → Privacy & Security → Microphone"])
            return false
        }
        if systemAudioPermission == .denied {
            status = StatusMessage(kind: .error, title: "No system audio access",
                                   details: ["System Settings → Privacy & Security → Screen & System Audio Recording"])
            return false
        }
        return true
    }

    private func resolveMicrophone() throws -> AudioHardwareDevice {
        let system = AudioHardwareSystem.shared
        if !selectedMicUID.isEmpty {
            guard let device = try system.device(forUID: selectedMicUID) else {
                throw RecorderError("the selected microphone is not connected")
            }
            return device
        }
        guard let device = try system.defaultInputDevice else { throw RecorderError("no default microphone") }
        return device
    }

    private func makeSessionFolder(_ source: CallSource) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let folder = Self.recordingsFolder.appending(path: "\(formatter.string(from: Date())) \(source.folderName)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func openRecordingsFolder() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(Self.recordingsFolder)
    }

    func openDiagnosticsLog() {
        NSWorkspace.shared.open(diagnostics.url)
    }

    func openPrivacySettings() {
        let anchor = micPermission == .denied ? "Privacy_Microphone" : "Privacy_ScreenCapture"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Fake state for design screenshots (`--preview <state>`).
    private func applyPreview(_ state: String) {
        let now = Date()
        let hour: TimeInterval = 3_600
        func fake(_ index: Int, _ source: String, _ ago: TimeInterval, _ duration: TimeInterval, _ problems: [String] = []) -> Recording {
            Recording(folder: Self.recordingsFolder.appending(path: "preview-\(index)"), source: source,
                      startedAt: now.addingTimeInterval(-ago), duration: duration, problems: problems, canPlay: true)
        }
        recordings = [
            fake(1, "FaceTime", hour, 3_476),
            fake(2, "Telegram", 3 * hour, 754),
            fake(3, "FaceTime", 26 * hour, 1_312, ["\"them\" track is completely silent"]),
            fake(4, "Telegram", 50 * hour, 95),
            fake(5, "FaceTime", 5 * 24 * hour, 2_210),
            fake(6, "Telegram", 9 * 24 * hour, 480),
        ]
        micPermission = .granted
        systemAudioPermission = .granted
        defaultMicName = "AirPods"
        activeProcesses = []
        if state.hasSuffix("playing") {
            playback.showPreview(recordings[0], progress: 0.35)
        }
        switch state {
        case "call":
            activeCall = .faceTime
        case "recording", "recording-ending":
            activeCall = .faceTime
            phase = .recording
            recordingSource = .faceTime
            recordingMicName = "AirPods"
            elapsedSeconds = 754
            localLevel = 0.62
            remoteLevel = 0.38
            if state == "recording-ending" {
                remoteLevel = 0
                remoteSilent = true
                remoteSilentSeconds = 25
                autoStopIn = 2
            }
        case "finishing":
            phase = .finishing
            recordingSource = .faceTime
        case "saved":
            status = StatusMessage(kind: .success, title: "Saved · 57:56")
        case "problems":
            status = StatusMessage(kind: .warning, title: "Saved · 21:52, with issues",
                                   details: ["\"them\" track is completely silent: no system audio access or the wrong process was tapped"])
        case "denied":
            activeCall = .telegram
            systemAudioPermission = .denied
        case "empty", "history-empty":
            recordings = []
        default:
            break
        }
    }

    /// `--selftest N`: record N seconds of all system audio and quit. For checking without a call.
    private func runSelfTestIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--selftest") else { return }
        let seconds = arguments.indices.contains(index + 1) ? Double(arguments[index + 1]) ?? 5 : 5
        Task {
            diagnostics.write("selftest: \(seconds) s, all system audio")
            await startRecording(.systemWide)
            if phase == .recording {
                try? await Task.sleep(for: .seconds(seconds))
                await stopRecording(reason: "self-test")
            }
            diagnostics.write("selftest: \(status?.title ?? "—") \(status?.details.joined(separator: "; ") ?? "")")
            NSApp.terminate(nil)
        }
    }
}
