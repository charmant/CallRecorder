import SwiftUI

// Menu bar panel. Glass is used only on controls (record button, bottom row):
// the system draws the panel background, while the header, levels, cards and history are content.

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Group {
            switch model.phase {
            case .recording:
                HStack(spacing: 4) {
                    Image(systemName: "record.circle.fill")
                    Text(model.elapsedText).monospacedDigit()
                }
                .accessibilityLabel("CallRecorder: recording, \(model.elapsedText)")
            case .finishing:
                Image(systemName: "arrow.down.circle")
                    .accessibilityLabel("CallRecorder: saving recording")
            case .idle:
                Image(systemName: model.activeCall == nil ? "waveform.circle" : "phone.circle.fill")
                    .accessibilityLabel(model.activeCall == nil ? "CallRecorder" : "CallRecorder: call in progress")
            }
        }
        .onAppear {
            if PreviewHarness.opensHistory { openWindow(id: HistoryWindow.id) }
            if PreviewHarness.opensTranscript, let first = model.recordings.first {
                openWindow(id: TranscriptWindow.id, value: first.folder)
            }
            if PreviewHarness.opensSettings { openSettings() }
            if PreviewHarness.opensFiling { openWindow(id: FilingWindow.id) }
        }
        // A transcript is ready: ask where it goes. The label lives as long as the app, so it can open windows.
        .onChange(of: model.filingQueue.first) { _, folder in
            if folder != nil { openWindow(id: FilingWindow.id) }
        }
    }
}

struct MenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PanelHeader(model: model)
            PrimaryControl(model: model)
            switch model.phase {
            case .idle:
                if let status = model.status { StatusCard(status: status) }
                if let transcription = model.transcription {
                    TranscriptionRow(status: transcription) { model.stopTranscription(transcription.folder) }
                }
                if !model.filingQueue.isEmpty {
                    FilingCallout(count: model.filingQueue.count) {
                        openWindow(id: FilingWindow.id)
                        NSApp.activate()
                    }
                }
                if !model.agentRuns.isEmpty {
                    AgentRow(count: model.agentRuns.count, agent: model.agent)
                }
                if model.permissionsDenied { PermissionCallout(model: model) }
                RecentSection(model: model)
            case .recording, .finishing:
                LevelsCard(model: model)
                    .opacity(model.phase == .finishing ? 0.4 : 1)
                RecordingNotes(model: model)
            }
            PanelFooter(model: model, openHistory: openHistory, openSettings: showSettings)
        }
        .padding(14)
        .frame(width: 300)
        .animation(reduceMotion ? .easeInOut(duration: 0.15) : .smooth(duration: 0.35), value: model.phase)
        .onAppear {
            model.refreshPermissions()
            model.reloadHistory()
        }
    }

    private func openHistory() {
        openWindow(id: HistoryWindow.id)
        NSApp.activate()
    }

    private func showSettings() {
        openSettings()
        NSApp.activate()
    }
}

// MARK: - Header

private struct PanelHeader: View {
    let model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: model.phase == .recording && !reduceMotion)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if model.phase == .recording {
                Text(model.elapsedText)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .contentTransition(reduceMotion ? .identity : .numericText())
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch model.phase {
        case .recording: "record.circle.fill"
        case .finishing: "arrow.down.circle"
        case .idle: model.activeCall == nil ? "phone.down" : "phone.fill"
        }
    }

    private var tint: Color {
        switch model.phase {
        case .recording: .red
        case .finishing: .secondary
        case .idle: model.activeCall == nil ? .secondary : .green
        }
    }

    private var title: String {
        switch model.phase {
        case .recording: "Recording · \(model.recordingSource?.title ?? "")"
        case .finishing: "Saving recording…"
        case .idle: model.activeCall.map { "Call in progress: \($0.title)" } ?? "No call detected"
        }
    }

    private var subtitle: String {
        switch model.phase {
        case .recording: "Microphone: \(model.recordingMicName)"
        case .finishing: "Mixing tracks into one file"
        case .idle:
            if model.activeCall == nil { "Start a call in FaceTime or Telegram" }
            else if model.permissionsDenied { "Access needed — see below" }
            else { "Stops automatically when the call ends" }
        }
    }
}

// MARK: - Record button

/// The same system .glassProminent button: "Record Call" → "Stop" → "Saving…".
private struct PrimaryControl: View {
    let model: AppModel

    var body: some View {
        Button(action: perform) {
            Label {
                Text(title)
            } icon: {
                if model.phase == .finishing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol).contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .tint(.red)
        .controlSize(.extraLarge)
        .disabled(!isEnabled)
        .keyboardShortcut(shortcut)
        .accessibilityHint(isEnabled ? "" : "Start a call in FaceTime or Telegram")
    }

    private var isEnabled: Bool {
        switch model.phase {
        case .idle: model.canRecord
        case .recording: true
        case .finishing: false
        }
    }

    private var title: String {
        switch model.phase {
        case .idle: "Record Call"
        case .recording: "Stop"
        case .finishing: "Saving…"
        }
    }

    private var symbol: String {
        model.phase == .recording ? "stop.fill" : "record.circle"
    }

    private var shortcut: KeyboardShortcut? {
        switch model.phase {
        case .idle: .defaultAction
        case .recording: KeyboardShortcut(".", modifiers: .command)
        case .finishing: nil
        }
    }

    private func perform() {
        switch model.phase {
        case .idle: Task { await model.startRecording() }
        case .recording: Task { await model.stopRecording(reason: "stopped manually") }
        case .finishing: break
        }
    }
}

// MARK: - While recording

/// The only place that reads the levels (10 times a second), so the rest of the panel doesn't redraw.
private struct LevelsCard: View {
    let model: AppModel

    var body: some View {
        GroupBox {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Label("You", systemImage: "mic.fill")
                    LevelGauge(title: "You", level: model.localLevel, silent: model.localSilent)
                }
                GridRow {
                    Label("Them", systemImage: "person.wave.2.fill")
                    LevelGauge(title: "Them", level: model.remoteLevel, silent: model.remoteSilent)
                }
            }
            .font(.callout)
            .padding(4)
        }
    }
}

private struct LevelGauge: View {
    let title: String
    let level: Float
    let silent: Bool

    var body: some View {
        HStack(spacing: 8) {
            // The label lives in the neighboring Grid column; labelsHidden doesn't hide the label on linearCapacity.
            Gauge(value: Double(level)) { EmptyView() }
                .gaugeStyle(.linearCapacity)
                .tint(Gradient(colors: [.green, .green, .yellow, .red]))
                .accessibilityLabel(title)
                .accessibilityValue(silent ? "silent" : "\(Int(level * 100)) %")
            Text("silent")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .opacity(silent ? 1 : 0)
        }
    }
}

private struct RecordingNotes: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let seconds = model.remoteSilentSeconds {
                Note(text: "Can't hear them for \(seconds) s. If they're talking, check system audio access.",
                     symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let warning = model.sessionWarning {
                Note(text: warning, symbol: "exclamationmark.triangle.fill", tint: .orange)
            }
            if let left = model.autoStopIn {
                Note(text: "Call ended — stopping in \(left) s", symbol: "phone.down.fill", tint: .secondary)
            }
        }
    }
}

private struct Note: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .font(.callout)
    }
}

// MARK: - Not recording

private struct StatusCard: View {
    let status: StatusMessage

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Label {
                    Text(status.title).fontWeight(.semibold)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                ForEach(status.details, id: \.self) { detail in
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
        }
    }

    private var symbol: String {
        switch status.kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        switch status.kind {
        case .success: .green
        case .warning: .orange
        case .error: .red
        }
    }
}

/// Shown only when a permission was denied — otherwise permissions live in Settings.
private struct PermissionCallout: View {
    let model: AppModel

    var body: some View {
        GroupBox {
            HStack(spacing: 8) {
                Label {
                    Text(text).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.red)
                }
                Spacer(minLength: 4)
                Button("Settings…", action: model.openPrivacySettings)
                    .help("Open Privacy & Security in System Settings")
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
            .font(.callout)
            .padding(2)
        }
    }

    private var text: String {
        switch (model.micPermission == .denied, model.systemAudioPermission == .denied) {
        case (true, true): "No microphone or system audio access"
        case (true, false): "No microphone access"
        default: "No system audio access"
        }
    }
}

/// Background transcription of the last recording (or the one-time model download).
private struct TranscriptionRow: View {
    let status: TranscriptionStatus
    let stop: () -> Void

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Label(status.downloadingModel ? "Downloading speech model (~610 MB)…" : "Transcribing on this Mac…",
                          systemImage: status.downloadingModel ? "arrow.down.circle" : "text.bubble")
                        .lineLimit(1)
                    Spacer()
                    Button("Stop Transcription", systemImage: "xmark.circle.fill", action: stop)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Stop transcription — you can start it again from the recording's menu")
                }
                ProgressView(value: status.progress)
            }
            .font(.callout)
            .padding(4)
        }
    }
}

/// Transcribed calls that haven't been filed to a project yet.
private struct FilingCallout: View {
    let count: Int
    let open: () -> Void

    var body: some View {
        GroupBox {
            HStack {
                Label(count == 1 ? "A call is waiting for a project" : "\(count) calls are waiting for a project",
                      systemImage: "tray.and.arrow.down")
                    .lineLimit(1)
                Spacer()
                Button("File…", action: open)
                    .buttonStyle(.glassProminent)
            }
            .font(.callout)
            .padding(4)
        }
    }
}

/// The agent is processing a filed call in the background.
private struct AgentRow: View {
    let count: Int
    let agent: AgentKind

    var body: some View {
        GroupBox {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(count == 1 ? "\(agent.title) is processing the call…" : "\(agent.title) is processing \(count) calls…")
                    .lineLimit(1)
                Spacer()
            }
            .font(.callout)
            .padding(4)
        }
    }
}

private struct RecentSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            if model.recentRecordings.isEmpty {
                Label("No recordings yet", systemImage: "tray")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 6)
            } else {
                ForEach(model.recentRecordings) { recording in
                    RecordingRow(recording: recording, model: model, style: .panel)
                }
            }
        }
    }
}

// MARK: - Panel footer

private struct PanelFooter: View {
    let model: AppModel
    let openHistory: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button("History…", systemImage: "clock.arrow.circlepath", action: openHistory)
                        .keyboardShortcut("y")
                    Button("Recordings Folder", systemImage: "folder", action: model.openRecordingsFolder)
                        .labelStyle(.iconOnly)
                        .help("Recordings Folder")
                    Button("Settings…", systemImage: "gearshape", action: openSettings)
                        .labelStyle(.iconOnly)
                        .help("Settings: microphone, permissions, diagnostics")
                        .keyboardShortcut(",")
                }
            }
            Spacer()
            Button("Quit", systemImage: "power") { NSApp.terminate(nil) }
                .labelStyle(.iconOnly)
                .help("Quit CallRecorder")
                .keyboardShortcut("q")
        }
        .buttonStyle(.glass)
    }
}

// MARK: - Recording row (panel and history window)

struct RecordingRow: View {
    enum Style {
        case panel, window
    }

    let recording: Recording
    let model: AppModel
    let style: Style
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row
            if model.playback.isCurrent(recording) {
                PlaybackControls(recording: recording, playback: model.playback)
                    .padding(.leading, 28)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 3)
        .contentShape(.rect)
        .contextMenu {
            if style == .panel { RecordingActions(recording: recording, model: model) }
        }
        .accessibilityElement(children: .contain)
    }

    private var row: some View {
        let playback = model.playback
        let isCurrent = playback.isCurrent(recording)
        return HStack(spacing: 10) {
            Image(systemName: recording.sourceSymbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(style == .panel ? recording.dayTimeText : RecordingDates.dayTime(recording.startedAt).components(separatedBy: ", ").last ?? "")
                    .font(.callout)
                Text(isCurrent ? playback.timeText : "\(recording.source) · \(recording.durationText)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if style == .window, let problem = recording.problems.first {
                    Text(problem).font(.caption).foregroundStyle(.orange).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if recording.hasProblems {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(recording.problems.joined(separator: "\n"))
                    .accessibilityLabel("Has issues")
            }
            if model.isTranscribing(recording) {
                ProgressView()
                    .controlSize(.mini)
                    .help("Transcribing…")
            } else if recording.hasTranscript {
                Button("Open Transcript", systemImage: "text.bubble") {
                    openWindow(id: TranscriptWindow.id, value: recording.folder)
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Open the transcript")
            }
            Button(playback.isPlaying(recording) ? "Pause" : "Play",
                   systemImage: playback.isPlaying(recording) ? "pause.circle.fill" : "play.circle.fill") {
                playback.toggle(recording)
            }
            .labelStyle(.iconOnly)
            .font(.title2)
            .buttonStyle(.borderless)
            .contentTransition(.symbolEffect(.replace))
            .disabled(!recording.canPlay)
            .help(recording.canPlay ? "Play" : "No conversation.m4a mix")
            if style == .panel {
                Menu {
                    RecordingActions(recording: recording, model: model)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .buttonStyle(.borderless)
                .menuIndicator(.hidden)
                .fixedSize()
                .accessibilityLabel("Actions")
            }
        }
    }
}

/// Waveform of the playing recording (click to jump to that spot) and a stop button.
private struct PlaybackControls: View {
    let recording: Recording
    let playback: Playback

    var body: some View {
        HStack(spacing: 8) {
            ConversationTimeline(recording: recording, playback: playback, height: 30)
            Button("Stop", systemImage: "stop.fill") { playback.stop() }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Stop")
        }
    }
}

struct RecordingActions: View {
    let recording: Recording
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(model.playback.isPlaying(recording) ? "Pause" : "Play", systemImage: "play") {
            model.playback.toggle(recording)
        }
        .disabled(!recording.canPlay)
        if model.playback.isCurrent(recording) {
            Button("Stop", systemImage: "stop") { model.playback.stop() }
        }
        if recording.hasTranscript {
            Button("Open Transcript", systemImage: "text.bubble") {
                openWindow(id: TranscriptWindow.id, value: recording.folder)
            }
        }
        if model.isTranscribing(recording) {
            Button("Stop Transcription", systemImage: "xmark.circle") { model.stopTranscription(recording.folder) }
        } else if recording.hasAudio {
            Button(recording.hasTranscript ? "Transcribe Again" : "Transcribe", systemImage: "waveform.badge.magnifyingglass") {
                model.transcribe(recording)
            }
        }
        if recording.hasTranscript, model.knowledgeBase != nil {
            if recording.filing != nil {
                Button("Show Filed Transcript", systemImage: "doc.text.magnifyingglass") { model.revealFiled(recording) }
            }
            Button(recording.filing == nil ? "Send to Project…" : "Send to Another Project…", systemImage: "tray.and.arrow.down") {
                model.requestFiling(recording)
                openWindow(id: FilingWindow.id)
                NSApp.activate()
            }
        }
        Button("Show in Finder", systemImage: "folder") { model.reveal(recording) }
        Divider()
        Button("Move to Trash", systemImage: "trash", role: .destructive) { model.moveToTrash(recording) }
    }
}
