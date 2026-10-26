import AppKit
import SwiftUI

/// Settings (⌘,): the microphone, permissions, recordings folder, knowledge base and diagnostics — everything the
/// panel doesn't need day to day.
struct SettingsScene: Scene {
    let model: AppModel

    var body: some Scene {
        Settings {
            SettingsView(model: model)
        }
    }
}

private struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                Picker("Microphone", selection: $model.selectedMicUID) {
                    Text("System Default (\(model.defaultMicName))").tag("")
                    ForEach(model.microphones) { microphone in
                        Text(microphone.name).tag(microphone.uid)
                    }
                }
            } header: {
                Text("Recording")
            } footer: {
                Text("Pick the microphone you talk into in FaceTime or Telegram.")
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                LabeledContent("Microphone") {
                    PermissionValue(state: model.micPermission, openSettings: model.openPrivacySettings)
                }
                LabeledContent("System audio") {
                    PermissionValue(state: model.systemAudioPermission, openSettings: model.openPrivacySettings)
                }
            }

            Section("Recordings") {
                LabeledContent("Folder") {
                    Button((AppModel.recordingsFolder.path as NSString).abbreviatingWithTildeInPath) {
                        model.openRecordingsFolder()
                    }
                    .buttonStyle(.link)
                }
            }

            Section {
                LabeledContent("Folder") {
                    HStack {
                        Text(model.knowledgeBasePath.isEmpty ? "Off" : (model.knowledgeBasePath as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseKnowledgeBase() }
                        if !model.knowledgeBasePath.isEmpty {
                            Button("Turn Off") { model.knowledgeBasePath = "" }
                        }
                    }
                }
                Toggle("Move audio to the Trash once the transcript is filed", isOn: $model.trashAudioAfterFiling)
                Toggle("Process the filed call with an agent (/call)", isOn: $model.runAgentAfterFiling)
                Picker("Agent", selection: $model.agent) {
                    ForEach(AgentKind.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.runAgentAfterFiling)
            } header: {
                Text("Knowledge Base")
            } footer: {
                Text("After each transcript the app asks which project the call belongs to and writes it to the project's calls/ folder. The agent runs headless in that folder and may only write there and to inbox/.")
                    .foregroundStyle(.secondary)
            }

            Section {
                if model.activeProcesses.isEmpty {
                    Text("No app is playing or recording audio right now.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.activeProcesses) { process in
                    LabeledContent {
                        HStack(spacing: 6) {
                            Image(systemName: "mic.fill").opacity(process.isRunningInput ? 1 : 0.15)
                            Image(systemName: "speaker.wave.2.fill").opacity(process.isRunningOutput ? 1 : 0.15)
                        }
                        .foregroundStyle(.secondary)
                    } label: {
                        Text("\(process.executable) · \(process.pid)")
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(process.executable), \(process.isRunningInput ? "microphone" : "") \(process.isRunningOutput ? "audio" : "")")
                }
                Button("Open Log") { model.openDiagnosticsLog() }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Apps using audio right now. If a call isn't detected, this list and the log show which process plays it.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .frame(minHeight: 680)
        .onAppear {
            model.refreshMicrophones()
            model.refreshPermissions()
            WindowActivation.opened()
        }
        .onDisappear { WindowActivation.closed() }
    }
}

extension SettingsView {
    private func chooseKnowledgeBase() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "The folder with 03_projects/ — the knowledge base calls are filed to"
        if !model.knowledgeBasePath.isEmpty { panel.directoryURL = URL(filePath: model.knowledgeBasePath) }
        if panel.runModal() == .OK, let url = panel.url { model.knowledgeBasePath = url.path }
    }
}

private struct PermissionValue: View {
    let state: PermissionState
    let openSettings: () -> Void

    var body: some View {
        switch state {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .unknown:
            Label("Asked on first recording", systemImage: "questionmark.circle").foregroundStyle(.secondary)
        case .denied:
            Button("Open Privacy Settings…", systemImage: "hand.raised.fill", action: openSettings)
                .buttonStyle(.glass)
                .tint(.red)
        }
    }
}
