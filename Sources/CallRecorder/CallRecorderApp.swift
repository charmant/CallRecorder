import SwiftUI

@main
struct CallRecorderApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        HistoryWindow(model: model)

        TranscriptWindow(model: model)

        FilingWindow(model: model)

        SettingsScene(model: model)
    }
}
