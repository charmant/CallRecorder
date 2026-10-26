import AppKit
import SwiftUI

/// A window with one recording's transcript, opened from the panel, a recording's menu or History.
struct TranscriptWindow: Scene {
    static let id = "transcript"
    let model: AppModel

    var body: some Scene {
        WindowGroup("Transcript", id: Self.id, for: URL.self) { $folder in
            if let folder {
                TranscriptView(folder: folder, model: model)
            }
        }
        .defaultSize(width: 760, height: 780)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

/// While any of our windows is open the app shows in the Dock and ⌘-Tab like a regular app.
@MainActor
enum WindowActivation {
    private static var openWindows = 0

    static func opened() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func closed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

private struct TranscriptView: View {
    let folder: URL
    let model: AppModel
    @State private var transcript: Transcript?
    @State private var loaded = false
    @State private var query = ""

    private var recording: Recording? {
        model.recordings.first { $0.folder == folder }
    }

    private var lines: [TranscriptLine] {
        let all = (transcript?.segments ?? []).enumerated().map { TranscriptLine(id: $0.offset, segment: $0.element) }
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return all }
        return all.filter { $0.segment.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        Group {
            if let transcript {
                VStack(spacing: 0) {
                    if let recording, recording.canPlay {
                        TranscriptPlayer(recording: recording, playback: model.playback)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 12)
                        Divider()
                    }
                    TranscriptLines(lines: lines, recording: recording, playback: model.playback)
                        .overlay {
                            if lines.isEmpty, !query.isEmpty { ContentUnavailableView.search(text: query) }
                        }
                }
                .navigationSubtitle("\(transcript.segments.count) lines · \(transcript.model)")
            } else if loaded {
                ContentUnavailableView {
                    Label("No transcript yet", systemImage: "text.bubble")
                } description: {
                    Text(model.transcription?.folder == folder ? "Transcribing…" : "This recording hasn't been transcribed.")
                } actions: {
                    if let recording, recording.hasAudio, !model.isTranscribing(recording) {
                        Button("Transcribe") { model.transcribe(recording) }
                            .buttonStyle(.glassProminent)
                    }
                }
            } else {
                ProgressView()
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .navigationTitle(recording.map { "\($0.source) · \($0.dayTimeText)" } ?? "Transcript")
        .searchable(text: $query, placement: .toolbar, prompt: "Search transcript")
        .toolbar {
            ToolbarItemGroup {
                Button("Copy All", systemImage: "doc.on.doc") { copyAll() }
                    .disabled(transcript == nil)
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([Transcript.markdownURL(in: folder)])
                }
                .disabled(transcript == nil)
            }
        }
        .task(id: "\(folder.path)|\(recording?.hasTranscript ?? false)") {
            transcript = PreviewHarness.state != nil ? Transcript.preview : await Self.load(folder)
            loaded = true
        }
        .onAppear { WindowActivation.opened() }
        .onDisappear { WindowActivation.closed() }
    }

    private static func load(_ folder: URL) async -> Transcript? {
        await Task.detached(priority: .userInitiated) { Transcript.load(from: folder) }.value
    }

    private func copyAll() {
        guard let transcript else { return }
        let text = transcript.segments
            .map { "[\(formatDuration($0.start))] \($0.speaker.title): \($0.text)" }
            .joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct TranscriptLine: Identifiable {
    let id: Int
    let segment: TranscriptSegment
}

/// Play/pause, position and the clickable conversation waveform.
private struct TranscriptPlayer: View {
    let recording: Recording
    let playback: Playback

    var body: some View {
        HStack(spacing: 14) {
            Button(playback.isPlaying(recording) ? "Pause" : "Play",
                   systemImage: playback.isPlaying(recording) ? "pause.fill" : "play.fill") {
                playback.toggle(recording)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .contentTransition(.symbolEffect(.replace))
            .keyboardShortcut(.space, modifiers: [])
            ConversationTimeline(recording: recording, playback: playback, height: 44)
            Text(playback.isCurrent(recording) ? playback.timeText : recording.durationText)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 96, alignment: .trailing)
        }
    }
}

/// The lines; while this recording plays, the current line is highlighted and kept in view.
private struct TranscriptLines: View {
    let lines: [TranscriptLine]
    let recording: Recording?
    let playback: Playback

    private var currentID: Int? {
        guard let recording, playback.isCurrent(recording) else { return nil }
        let time = playback.elapsed
        return lines.last { $0.segment.start <= time }?.id
    }

    var body: some View {
        let current = currentID
        ScrollViewReader { proxy in
            List(lines) { line in
                TranscriptRow(segment: line.segment, isCurrent: line.id == current) {
                    guard let recording, recording.canPlay else { return }
                    playback.play(recording, at: line.segment.start / max(recording.duration, 1))
                }
                .equatable()
                .listRowBackground(line.id == current ? Color.accentColor.opacity(0.12) : Color.clear)
                .id(line.id)
            }
            .listStyle(.inset)
            .onChange(of: current) { _, id in
                guard let id, playback.isPlaying else { return }
                withAnimation { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }
}

private struct TranscriptRow: View, Equatable {
    let segment: TranscriptSegment
    let isCurrent: Bool
    let seek: () -> Void

    static func == (lhs: TranscriptRow, rhs: TranscriptRow) -> Bool {
        lhs.segment == rhs.segment && lhs.isCurrent == rhs.isCurrent
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(formatDuration(segment.start), action: seek)
                .buttonStyle(.link)
                .font(.callout.monospacedDigit())
                .help("Play from here")
            Text(segment.speaker.title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(segment.speaker == .you ? Color.green : Color.blue)
                .frame(width: 44, alignment: .leading)
            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

extension Transcript {
    /// Made-up lines for design screenshots (`--preview transcript`); never real call content.
    static let preview = Transcript(
        model: "Parakeet Ultra", createdAt: Date(), processingSeconds: 91,
        segments: [
            ("them", 4, 7, "Hi! Can you hear me well?"),
            ("you", 8, 10, "Yes, loud and clear."),
            ("them", 11, 17, "Great. Let's go through the plan for the new release first."),
            ("you", 18, 24, "Sure. The recorder is done, transcription works, and the history window got a search field."),
            ("them", 25, 29, "Nice. What about summaries?"),
            ("you", 30, 36, "That's next. I'd like to try it on a few real calls before choosing a model."),
            ("them", 37, 40, "Makes sense."),
            ("you", 41, 47, "I'll send you a build on Friday, and we can test it together next week."),
            ("them", 48, 50, "Deal. Talk soon!"),
        ].map { TranscriptSegment(speaker: $0.0 == "you" ? .you : .them, start: $0.1, end: $0.2, text: $0.3) }
    )
}
