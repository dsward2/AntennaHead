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
            CommandGroup(after: .windowArrangement) {
                FCCSearchWindowCommand()
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
