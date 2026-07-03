import SwiftUI

@main
struct AntennaHeadApp: App {
    init() {
        _ = AppDatabase.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            // Port of LocalRadio's Commands menu. (Show Custom Tasks Window is
            // intentionally absent — custom tasks live in the web UI here.)
            CommandMenu("Commands") {
                FCCSearchWindowCommand()
                Button("Reload Web View") {
                    NotificationCenter.default.post(name: WebRadioView.reloadNotification, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Window("FCC Station Search", id: "fcc-search") {
            FCCSearchView()
        }
        .defaultSize(width: 480, height: 560)
    }
}

struct FCCSearchWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("FCC Station Search") {
            openWindow(id: "fcc-search")
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
    }
}
