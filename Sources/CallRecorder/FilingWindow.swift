import SwiftUI

/// "File Call": after a call is transcribed, asks which project it belongs to and files the transcript
/// into that project's calls/ folder in the knowledge base.
struct FilingWindow: Scene {
    static let id = "filing"
    let model: AppModel

    var body: some Scene {
        Window("File Call", id: Self.id) {
            FilingView(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

private struct FilingView: View {
    let model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var destinations: [FilingDestination] = []
    @State private var selection: FilingDestination.ID?
    @State private var topic = ""
    @State private var query = ""
    @State private var firstLines: [TranscriptSegment] = []

    private var folder: URL? { model.filingQueue.first }
    private var recording: Recording? { model.recordings.first { $0.folder == folder } }

    private var filtered: [FilingDestination] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return destinations }
        return destinations.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var selected: FilingDestination? { destinations.first { $0.id == selection } }

    var body: some View {
        Group {
            if let folder {
                form(folder)
            } else {
                ContentUnavailableView("Nothing to file", systemImage: "tray",
                                       description: Text("Transcribed calls show up here."))
                    .frame(width: 460, height: 320)
            }
        }
        .onAppear { WindowActivation.opened() }
        .onDisappear { WindowActivation.closed() }
        .onChange(of: model.filingQueue.isEmpty) { _, isEmpty in
            if isEmpty { dismissWindow(id: FilingWindow.id) }
        }
    }

    private func form(_ folder: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(recording.map { "\($0.source) · \($0.dayTimeText) · \($0.durationText)" } ?? folder.lastPathComponent,
                      systemImage: recording?.sourceSymbol ?? "waveform")
                    .font(.headline)
                Spacer()
                if model.filingQueue.count > 1 {
                    Text("1 of \(model.filingQueue.count)").foregroundStyle(.secondary)
                }
            }

            if !firstLines.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(firstLines.enumerated()), id: \.offset) { _, segment in
                            Text("\(Text("\(segment.speaker.title):").fontWeight(.semibold)) \(segment.text)")
                                .lineLimit(2)
                        }
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                }
                .accessibilityLabel("Start of the transcript")
            }

            TextField("Topic", text: $topic, prompt: Text("What the call was about (optional)"))

            VStack(alignment: .leading, spacing: 6) {
                TextField("Filter", text: $query, prompt: Text("Filter projects"))
                    .textFieldStyle(.roundedBorder)
                List(filtered, selection: $selection) { destination in
                    Label(destination.title, systemImage: symbol(destination))
                        .padding(.leading, destination.kind == .part ? 16 : 0)
                        .tag(destination.id)
                }
                .listStyle(.bordered)
                .frame(height: 230)
                .overlay {
                    if destinations.isEmpty {
                        ContentUnavailableView("No projects", systemImage: "folder.badge.questionmark",
                                               description: Text("Pick the knowledge base folder in Settings."))
                    }
                }
            }

            if let selected {
                Text("Goes to \(abbreviated(selected.callsFolder))"
                     + (model.trashAudioAfterFiling ? ", the audio to the Trash" : "")
                     + (model.runAgentAfterFiling && selected.kind != .inbox ? ", then \(model.agent.title) runs /call" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Later") { model.postponeFiling(folder) }
                    .keyboardShortcut(.cancelAction)
                    .help("Keep the recording unfiled — Send to Project… in its menu asks again")
                Spacer()
                Button("File") {
                    if let selected { model.file(folder, to: selected, topic: topic) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(selected == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task(id: folder) {
            destinations = model.filingDestinations()
            let last = model.lastFilingDestination
            selection = destinations.contains { $0.id == last } ? last : nil
            topic = ""
            query = ""
            let transcript = await Task.detached(priority: .userInitiated) {
                PreviewHarness.state != nil ? Transcript.preview : Transcript.load(from: folder)
            }.value
            firstLines = Array((transcript?.segments ?? []).prefix(4))
        }
    }

    private func symbol(_ destination: FilingDestination) -> String {
        switch destination.kind {
        case .project: "folder"
        case .part: "person.crop.square"
        case .inbox: "tray"
        }
    }

    private func abbreviated(_ url: URL) -> String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }
}
