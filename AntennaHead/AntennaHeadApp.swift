import SwiftUI
import AppKit
import SharedLogging

@main
struct AntennaHeadApp: App {
    init() {
        _ = AppDatabase.shared
        LogStore.shared.configure(appName: "AntennaHead")
        launchControlBoothIfConfigured()
    }

    private func launchControlBoothIfConfigured() {
        let shouldLaunch = (try? SQLiteController.shared.appSettingsValue(
            forKey: ConfigurationView.controlBoothAutoLaunchKey)) == "1"
        guard shouldLaunch else { return }

        // Try security-scoped bookmark first (required for sandbox access to non-standard locations)
        if let base64 = (try? SQLiteController.shared.appSettingsValue(
            forKey: ConfigurationView.controlBoothBookmarkKey)) ?? nil,
           let data = Data(base64Encoded: base64) {
            var isStale = false
            if let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                  relativeTo: nil, bookmarkDataIsStale: &isStale) {
                let accessed = url.startAccessingSecurityScopedResource()
                NSWorkspace.shared.open(url)
                if accessed { url.stopAccessingSecurityScopedResource() }
                return
            }
        }

        // Fall back to plain path (works for /Applications and other sandbox-accessible locations)
        let rawPath = ((try? SQLiteController.shared.appSettingsValue(
            forKey: ConfigurationView.controlBoothPathKey)) ?? nil) ?? ""
        let path = rawPath.isEmpty ? "/Applications/ControlBooth.app" : rawPath
        guard FileManager.default.fileExists(atPath: path) else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                AboutWindowCommand()
            }
            CommandGroup(replacing: .newItem) {}
            // The main window has a close button but no ⌘N; without this the
            // window can't be brought back once closed.
            CommandGroup(after: .windowList) {
                MainWindowCommand()
            }
            // Port of LocalRadio's Commands menu. (Show Custom Tasks Window is
            // intentionally absent — custom tasks live in the web UI here.)
            CommandMenu("Commands") {
                FCCSearchWindowCommand()
                LogsWindowCommand()
                RevealRecordingsFolderCommand()
                Button("Reload Web View") {
                    NotificationCenter.default.post(name: WebRadioView.reloadNotification, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
            }
        }

        Window("About AntennaHead", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)

        Window("FCC Station Search", id: "fcc-search") {
            FCCSearchView()
        }
        .defaultSize(width: 480, height: 560)

        Window("Logs", id: "logs") {
            LogViewerView()
        }
        .defaultSize(width: 800, height: 500)
    }
}

struct MainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("AntennaHead Window") {
            openWindow(id: "main")
        }
        .keyboardShortcut("1", modifiers: .command)
    }
}

struct AboutWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About AntennaHead") {
            openWindow(id: "about")
        }
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

struct LogsWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Logs") {
            openWindow(id: "logs")
        }
        .keyboardShortcut("l", modifiers: [.command, .shift])
    }
}

struct RevealRecordingsFolderCommand: View {
    var body: some View {
        Button("Show Recordings Folder in Finder") {
            guard let url = SharedRecordingFolder.url else {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Recordings folder unavailable"
                alert.informativeText = "AntennaHead's shared recording folder isn't available — check its App Group entitlement."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return
            }
            NSWorkspace.shared.open(url)
        }
        .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}
