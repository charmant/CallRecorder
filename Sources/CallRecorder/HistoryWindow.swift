import SwiftUI

/// The "Recording History" window: system sidebar, table, search, inspector and toolbar —
/// the glass here is entirely system-provided.
struct HistoryWindow: Scene {
    static let id = "history"
    let model: AppModel

    var body: some Scene {
        Window("Recording History", id: Self.id) {
            HistoryView(model: model)
        }
        .defaultSize(width: 1040, height: 600)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct HistoryView: View {
    let model: AppModel
    @State private var filter: HistoryFilter? = .all
    @State private var query = ""
    @State private var selection: Recording.ID?
    @State private var showInspector = true

    private var filtered: [Recording] {
        model.recordings.filter { (filter ?? .all).includes($0) && $0.matches(query) }
    }

    private var selected: Recording? {
        model.recordings.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $filter) {
                ForEach(HistoryFilter.allCases) { item in
                    Label(item.title, systemImage: item.symbol)
                        .badge(model.recordings.filter(item.includes).count)
                        .tag(item)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            RecordingsTable(recordings: filtered, model: model, selection: $selection)
                .overlay { emptyState }
                .inspector(isPresented: $showInspector) {
                    RecordingInspector(recording: selected, model: model)
                        .inspectorColumnWidth(min: 240, ideal: 280, max: 380)
                }
        }
        .navigationTitle((filter ?? .all).title)
        .navigationSubtitle(countText)
        .searchable(text: $query, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup {
                Button("Show in Finder", systemImage: "folder") {
                    if let selected { model.reveal(selected) }
                }
                .disabled(selected == nil)
                Button("Move to Trash", systemImage: "trash") {
                    if let selected { model.moveToTrash(selected) }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selected == nil)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button("Details", systemImage: "sidebar.trailing") { showInspector.toggle() }
            }
        }
        .onAppear {
            model.reloadHistory()
            if PreviewHarness.opensHistory, selection == nil { selection = model.recordings.first?.id }
            // While the window is open, the app shows in the Dock and ⌘-Tab, like a regular window.
            NSApp.setActivationPolicy(.regular)
            NSApp.activate()
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private var countText: String {
        let total = filtered.reduce(0) { $0 + $1.duration }
        return "\(filtered.count) · \(formatDuration(total))"
    }

    @ViewBuilder private var emptyState: some View {
        if filtered.isEmpty {
            if !query.isEmpty {
                ContentUnavailableView.search(text: query)
            } else if filter == .problems {
                ContentUnavailableView("No recordings with issues", systemImage: "checkmark.circle")
            } else {
                ContentUnavailableView("No recordings yet", systemImage: "tray",
                                       description: Text("Record a call from the menu bar and it will appear here"))
            }
        }
    }
}

private struct RecordingsTable: View {
    let recordings: [Recording]
    let model: AppModel
    @Binding var selection: Recording.ID?

    var body: some View {
        Table(of: Recording.self, selection: $selection) {
            TableColumn("") { recording in
                if model.playback.isCurrent(recording) {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, isActive: model.playback.isPlaying)
                        .accessibilityLabel("Playing")
                }
            }
            .width(20)
            TableColumn("Time") { recording in
                Text(RecordingDates.time(recording.startedAt)).monospacedDigit()
            }
            .width(min: 48, ideal: 52, max: 64)
            TableColumn("Source") { recording in
                Label(recording.source, systemImage: recording.sourceSymbol)
            }
            .width(min: 96, ideal: 110, max: 140)
            TableColumn("Duration") { recording in
                Text(recording.durationText).monospacedDigit()
            }
            .width(min: 72, ideal: 84, max: 110)
            TableColumn("Status") { recording in
                if let problem = recording.problems.first {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                        .help(recording.problems.joined(separator: "\n"))
                } else {
                    Label("OK", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                }
            }
        } rows: {
            ForEach(RecordingDay.group(recordings)) { day in
                Section(day.title) {
                    ForEach(day.recordings) { recording in
                        TableRow(recording)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: Recording.ID.self) { ids in
            if let recording = recording(for: ids) {
                RecordingActions(recording: recording, model: model)
            }
        } primaryAction: { ids in
            if let recording = recording(for: ids), recording.canPlay {
                model.playback.toggle(recording)
            }
        }
        .onKeyPress(.space) {
            guard let recording = recording(for: selection.map { [$0] } ?? []), recording.canPlay else { return .ignored }
            model.playback.toggle(recording)
            return .handled
        }
    }

    private func recording(for ids: some Collection<Recording.ID>) -> Recording? {
        guard let id = ids.first else { return nil }
        return recordings.first { $0.id == id }
    }
}

private struct RecordingInspector: View {
    let recording: Recording?
    let model: AppModel

    var body: some View {
        if let recording {
            Form {
                Section {
                    if recording.canPlay {
                        InspectorPlayer(recording: recording, playback: model.playback)
                    } else {
                        Label("No conversation.m4a mix", systemImage: "speaker.slash")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Details") {
                    LabeledContent("Started", value: RecordingDates.full(recording.startedAt))
                    LabeledContent("Source", value: recording.source)
                    LabeledContent("Duration", value: recording.durationText)
                    LabeledContent("Folder") {
                        Button(recording.folder.lastPathComponent) { model.reveal(recording) }
                            .buttonStyle(.link)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                if recording.hasProblems {
                    Section("Issues") {
                        ForEach(recording.problems, id: \.self) { problem in
                            Label {
                                Text(problem).textSelection(.enabled)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        } else {
            ContentUnavailableView("Select a recording", systemImage: "waveform",
                                   description: Text("Recording details appear here"))
        }
    }
}

/// Waveform of the selected recording — click anywhere to play from there — with buttons below it.
private struct InspectorPlayer: View {
    let recording: Recording
    let playback: Playback

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ConversationTimeline(recording: recording, playback: playback, height: 64)
                .padding(.top, 14)
            HStack(spacing: 12) {
                Button(playback.isPlaying(recording) ? "Pause" : "Play",
                       systemImage: playback.isPlaying(recording) ? "pause.fill" : "play.fill") {
                    playback.toggle(recording)
                }
                .buttonStyle(.glassProminent)
                .contentTransition(.symbolEffect(.replace))
                Text(playback.isCurrent(recording) ? playback.timeText : recording.durationText)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if playback.isCurrent(recording) {
                    Button("Stop", systemImage: "stop.fill") { playback.stop() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .help("Stop")
                }
            }
            HStack(spacing: 12) {
                Label("them", systemImage: "square.fill").foregroundStyle(.blue)
                Label("you", systemImage: "square.fill").foregroundStyle(.green)
            }
            .font(.caption)
            .labelStyle(.titleAndIcon)
        }
    }
}
