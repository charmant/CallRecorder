import AppKit
import CoreAudio
import FluidAudio
import Observation

struct MicrophoneOption: Identifiable, Hashable {
    let uid: String
    let name: String
    var id: String { uid }
}

/// Progress of the recording being transcribed.
struct TranscriptionStatus: Equatable {
    let folder: URL
    var downloadingModel = false
    var progress: Double = 0
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
    /// The transcription in progress, if any — shown in the panel and next to the recording.
    private(set) var transcription: TranscriptionStatus?
    /// Transcribed recordings waiting for the user to pick a project; the first one is shown in the
    /// "File Call" window.
    private(set) var filingQueue: [URL] = []
    /// Recordings whose filed transcript the agent is working on right now.
    private(set) var agentRuns: Set<URL> = []
    let playback = Playback()

    /// Empty string means the system default microphone.
    var selectedMicUID = UserDefaults.standard.string(forKey: "micUID") ?? "" {
        didSet { UserDefaults.standard.set(selectedMicUID, forKey: "micUID") }
    }

    /// The knowledge base transcripts are filed to (~/Work); empty turns filing off.
    var knowledgeBasePath = UserDefaults.standard.string(forKey: "knowledgeBase") ?? AppModel.defaultKnowledgeBase {
        didSet { UserDefaults.standard.set(knowledgeBasePath, forKey: "knowledgeBase") }
    }
    /// The audio is only needed until the transcript is in the knowledge base.
    var trashAudioAfterFiling = UserDefaults.standard.object(forKey: "trashAudioAfterFiling") as? Bool ?? true {
        didSet { UserDefaults.standard.set(trashAudioAfterFiling, forKey: "trashAudioAfterFiling") }
    }
    var runAgentAfterFiling = UserDefaults.standard.object(forKey: "runAgentAfterFiling") as? Bool ?? true {
        didSet { UserDefaults.standard.set(runAgentAfterFiling, forKey: "runAgentAfterFiling") }
    }
    var agent = AgentKind(rawValue: UserDefaults.standard.string(forKey: "agent") ?? "") ?? .claude {
        didSet { UserDefaults.standard.set(agent.rawValue, forKey: "agent") }
    }

    @ObservationIgnored private let diagnostics: DiagnosticLog
    @ObservationIgnored private let monitor: ProcessMonitor
    @ObservationIgnored private var session: CaptureSession?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var sawCallDuringRecording = false
    @ObservationIgnored private var callEndedAt: Date?
    @ObservationIgnored private var transcriptionQueue: [URL] = []
    @ObservationIgnored private var transcriptionRunning = false
    @ObservationIgnored private var transcriptionJob: Task<Transcript, Error>?

    /// How many seconds the call app must stay off the microphone before recording stops.
    private let autoStopDelay: TimeInterval = 3

    var elapsedText: String { formatDuration(TimeInterval(elapsedSeconds)) }
    var permissionsDenied: Bool { micPermission == .denied || systemAudioPermission == .denied }
    /// Recording is available only when a call is visible: the source is always detected automatically.
    var canRecord: Bool { phase == .idle && activeCall != nil && !permissionsDenied }
    var recentRecordings: [Recording] { Array(recordings.prefix(5)) }
    var knowledgeBase: URL? {
        knowledgeBasePath.isEmpty ? nil : URL(filePath: knowledgeBasePath, directoryHint: .isDirectory)
    }

    private static var defaultKnowledgeBase: String {
        let work = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Work", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: work.path) ? work.path : ""
    }

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
            runTranscriptionCommandIfRequested()
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
        if session.source != .systemWide, result.duration > 1 {
            enqueueTranscription(session.folder)
        }
    }

    // MARK: - Transcription

    func isTranscribing(_ recording: Recording) -> Bool {
        transcription?.folder == recording.folder || transcriptionQueue.contains(recording.folder)
    }

    func transcribe(_ recording: Recording) {
        enqueueTranscription(recording.folder)
    }

    /// Stops the transcription in progress (nothing is saved) or takes a waiting recording out of the queue.
    func stopTranscription(_ folder: URL) {
        transcriptionQueue.removeAll { $0 == folder }
        if transcription?.folder == folder { transcriptionJob?.cancel() }
    }


    private func enqueueTranscription(_ folder: URL) {
        guard transcription?.folder != folder, !transcriptionQueue.contains(folder) else { return }
        transcriptionQueue.append(folder)
        guard !transcriptionRunning else { return }
        transcriptionRunning = true
        Task { await runTranscriptionQueue() }
    }

    /// One recording at a time and never during a call; the model is unloaded once the queue is empty.
    private func runTranscriptionQueue() async {
        while true {
            while !transcriptionQueue.isEmpty {
                while phase != .idle { try? await Task.sleep(for: .seconds(2)) }
                let folder = transcriptionQueue.removeFirst()
                transcription = TranscriptionStatus(folder: folder)
                // One retry for failures that aren't a user stop: once, right after a run stopped mid-way,
                // the next model load failed spuriously and a reload fixed it.
                for attempt in 1...2 {
                    let job = Task {
                        try await Transcriber.shared.transcribe(folder: folder) { [weak self] progress in
                            Task { @MainActor in self?.updateTranscription(folder, progress) }
                        }
                    }
                    transcriptionJob = job
                    do {
                        let transcript = try await job.value
                        diagnostics.write("transcript: \(transcript.segments.count) segments in \(Int(transcript.processingSeconds)) s → \(folder.lastPathComponent)")
                        if knowledgeBase != nil, FilingRecord.load(from: folder) == nil, !transcript.segments.isEmpty {
                            askToFile(folder)
                        }
                        break
                    } catch is CancellationError where job.isCancelled {
                        diagnostics.write("transcription stopped: \(folder.lastPathComponent)")
                        break
                    } catch {
                        diagnostics.write("✗ transcription failed (attempt \(attempt)): \(String(describing: error))")
                        await Transcriber.shared.unload()
                        if attempt == 2 {
                            status = StatusMessage(kind: .error, title: "Couldn't transcribe the recording", details: [error.localizedDescription])
                        }
                    }
                }
                transcriptionJob = nil
                transcription = nil
                reloadHistory()
            }
            await Transcriber.shared.unload()
            if transcriptionQueue.isEmpty { break }
        }
        transcriptionRunning = false
    }

    private func updateTranscription(_ folder: URL, _ progress: Transcriber.Progress) {
        guard transcription?.folder == folder else { return }
        switch progress {
        case .downloadingModel(let value):
            transcription?.downloadingModel = true
            transcription?.progress = value
        case .transcribing(let value):
            transcription?.downloadingModel = false
            transcription?.progress = value
        }
    }

    // MARK: - Filing

    /// Projects, clients and the inbox of the knowledge base, read from disk.
    func filingDestinations() -> [FilingDestination] {
        knowledgeBase.map(KnowledgeBase.destinations(in:)) ?? []
    }

    var lastFilingDestination: String? { UserDefaults.standard.string(forKey: "lastFilingDestination") }

    /// "Send to Project…" for a recording that is already transcribed — puts it first in the queue.
    func requestFiling(_ recording: Recording) {
        filingQueue.removeAll { $0 == recording.folder }
        filingQueue.insert(recording.folder, at: 0)
    }

    /// The user closed the question with "Later": the recording stays unfiled, and "Send to Project…"
    /// in its menu brings the question back.
    func postponeFiling(_ folder: URL) {
        filingQueue.removeAll { $0 == folder }
    }

    func file(_ folder: URL, to destination: FilingDestination, topic: String) {
        let url: URL
        do {
            url = try KnowledgeBase.file(recording: folder, to: destination, topic: topic)
        } catch {
            status = StatusMessage(kind: .error, title: "Couldn't file the transcript", details: [error.localizedDescription])
            diagnostics.write("✗ filing failed: \(folder.lastPathComponent): \(error.localizedDescription)")
            return
        }
        filingQueue.removeAll { $0 == folder }
        UserDefaults.standard.set(destination.id, forKey: "lastFilingDestination")
        diagnostics.write("filed: \(folder.lastPathComponent) → \(url.path)")
        var details: [String] = []
        // Only after the transcript is safely written: the audio goes to the Trash, not away for good.
        if trashAudioAfterFiling {
            if let current = recordings.first(where: { $0.folder == folder }), playback.isCurrent(current) { playback.stop() }
            let failed = KnowledgeBase.trashAudio(in: folder)
            if !failed.isEmpty { details.append("Couldn't move to Trash: \(failed.joined(separator: ", "))") }
        }
        status = StatusMessage(kind: details.isEmpty ? .success : .warning, title: "Filed to \(destination.title)", details: details)
        reloadHistory()
        if runAgentAfterFiling, destination.kind != .inbox {
            runAgent(on: url, in: destination, root: knowledgeBase, recording: folder)
        }
    }

    func revealFiled(_ recording: Recording) {
        guard let path = recording.filing?.file else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
    }

    private func askToFile(_ folder: URL) {
        guard !filingQueue.contains(folder) else { return }
        filingQueue.append(folder)
        Notifier.post(title: "Transcript ready", body: "Pick the project this call belongs to.")
    }

    /// Runs /call headless on the filed transcript: inside the destination folder, plus inbox/ for notes
    /// about Sergei that the skill must not write into his own files.
    private func runAgent(on file: URL, in destination: FilingDestination, root: URL?, recording folder: URL) {
        guard let root else { return }
        let log = folder.appending(path: "agent.log")
        do {
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let output = try FileHandle(forWritingTo: log)
            let process = Process()
            process.executableURL = URL(filePath: "/bin/zsh")
            process.arguments = ["-lc", agent.command]
            process.currentDirectoryURL = destination.folder
            var environment = ProcessInfo.processInfo.environment
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            environment["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
            environment["CALL_FILE"] = file.path
            environment["KB_INBOX"] = root.appending(path: KnowledgeBase.inboxPath).path
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = output
            process.terminationHandler = { [weak self] process in
                try? output.close()
                let code = process.terminationStatus
                Task { @MainActor in self?.agentFinished(folder, log: log, code: code, title: destination.title) }
            }
            try process.run()
            agentRuns.insert(folder)
            diagnostics.write("agent (\(agent.rawValue)) started: \(file.lastPathComponent) in \(destination.folder.path)")
        } catch {
            status = StatusMessage(kind: .error, title: "Couldn't start the agent", details: [error.localizedDescription])
            diagnostics.write("✗ agent failed to start: \(error.localizedDescription)")
        }
    }

    private func agentFinished(_ folder: URL, log: URL, code: Int32, title: String) {
        agentRuns.remove(folder)
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        let summary = text.split(separator: "\n").suffix(3).map(String.init)
        diagnostics.write("agent finished with \(code): \(folder.lastPathComponent)")
        if code == 0 {
            status = StatusMessage(kind: .success, title: "Agent processed the call · \(title)", details: summary)
            Notifier.post(title: "Call processed · \(title)", body: summary.joined(separator: "\n"))
        } else {
            status = StatusMessage(kind: .error, title: "The agent failed (exit \(code))", details: summary + ["Log: \(log.path)"])
            Notifier.post(title: "The agent failed · \(title)", body: summary.last ?? "See agent.log in the recording folder.")
        }
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
        case "transcribing":
            recordings[1].hasTranscript = true
            recordings[2].hasTranscript = true
            transcription = TranscriptionStatus(folder: recordings[0].folder, progress: 0.42)
        case "filing", "waiting":
            recordings[0].hasTranscript = true
            filingQueue = [recordings[0].folder]
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

    /// Command-line hooks for testing transcription without the UI, then quit:
    /// `--transcribe <recording folder>` and `--transcribe-clips <folder of .wav> <out.json>`.
    private func runTranscriptionCommandIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "--file-call"), arguments.indices.contains(index + 3) {
            runFileCallCommand(recording: arguments[index + 1], knowledgeBase: arguments[index + 2], destination: arguments[index + 3])
            return
        }
        if let index = arguments.firstIndex(of: "--model"), arguments.indices.contains(index + 1) {
            Transcriber.modelVersion = arguments[index + 1] == "ultra" ? .ultra : .v3
        }
        if let index = arguments.firstIndex(of: "--encoder"), arguments.indices.contains(index + 1),
           let precision = ParakeetEncoderPrecision(rawValue: arguments[index + 1]) {
            Transcriber.encoderPrecision = precision
        }
        if let index = arguments.firstIndex(of: "--enqueue-transcription"), arguments.indices.contains(index + 1) {
            // Same path as after a call: through the queue, with progress and unloading the model at the end.
            let folder = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
            enqueueTranscription(folder)
            if let stopIndex = arguments.firstIndex(of: "--stop-after"), arguments.indices.contains(stopIndex + 1),
               let seconds = Double(arguments[stopIndex + 1]) {
                Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    stopTranscription(folder)
                }
            }
            Task {
                while transcriptionRunning { try? await Task.sleep(for: .milliseconds(200)) }
                diagnostics.write("queue finished; last status: \(status?.title ?? "none")")
                NSApp.terminate(nil)
            }
        } else if let index = arguments.firstIndex(of: "--transcribe"), arguments.indices.contains(index + 1) {
            let folder = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
            Task {
                do {
                    let transcript = try await Transcriber.shared.transcribe(folder: folder) { _ in }
                    diagnostics.write("transcribe: \(transcript.segments.count) segments in \(Int(transcript.processingSeconds)) s → \(folder.path)")
                } catch {
                    diagnostics.write("transcribe failed: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
        } else if let index = arguments.firstIndex(of: "--transcribe-clips"), arguments.indices.contains(index + 2) {
            let folder = URL(filePath: arguments[index + 1], directoryHint: .isDirectory)
            let output = URL(filePath: arguments[index + 2])
            Task {
                do {
                    let clips = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                        .filter { $0.pathExtension == "wav" }
                        .sorted { $0.lastPathComponent < $1.lastPathComponent }
                    let started = Date()
                    let texts = try await Transcriber.shared.transcribeClips(clips)
                    let data = try JSONSerialization.data(withJSONObject: ["texts": texts, "seconds": Date().timeIntervalSince(started)],
                                                          options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: output)
                } catch {
                    diagnostics.write("transcribe-clips failed: \(error.localizedDescription)")
                }
                NSApp.terminate(nil)
            }
        }
    }

    /// `--file-call <recording folder> <knowledge base> <destination id>`: files the transcript into that
    /// knowledge base, runs the agent if it's turned on and waits for it, then quits. The audio stays.
    private func runFileCallCommand(recording: String, knowledgeBase path: String, destination id: String) {
        let folder = URL(filePath: recording, directoryHint: .isDirectory)
        let root = URL(filePath: path, directoryHint: .isDirectory)
        Task {
            if let destination = KnowledgeBase.destinations(in: root).first(where: { $0.id == id }) {
                do {
                    let url = try KnowledgeBase.file(recording: folder, to: destination, topic: "")
                    diagnostics.write("file-call: → \(url.path)")
                    if runAgentAfterFiling, destination.kind != .inbox {
                        runAgent(on: url, in: destination, root: root, recording: folder)
                        while !agentRuns.isEmpty { try? await Task.sleep(for: .milliseconds(500)) }
                    }
                    diagnostics.write("file-call: done; last status: \(status?.title ?? "none")")
                } catch {
                    diagnostics.write("file-call failed: \(error.localizedDescription)")
                }
            } else {
                diagnostics.write("file-call: no destination \(id) in \(root.path)")
            }
            NSApp.terminate(nil)
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
