import SwiftUI

struct AboutView: View {
    private static let githubURL = URL(string: "https://github.com/dsward2/AntennaHead")!

    private var version: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        return "v\(v)"
    }

    /// Set by macOS only when the process is running under the App Sandbox
    /// (see `com.apple.security.app-sandbox`). AntennaHead ships sandboxed,
    /// so this should normally read "Enabled".
    private var appSandboxStatus: String {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil ? "Enabled" : "Disabled"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 80, height: 80)
                .padding(.bottom, 12)

            Text("AntennaHead")
                .font(.title2.weight(.semibold))

            Text(version)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 16)

            Divider()
                .padding(.bottom, 14)

            VStack(spacing: 6) {
                Link("github.com/dsward2/AntennaHead", destination: Self.githubURL)
                    .font(.callout)

                Text("© 2025 Douglas Ward")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Text("Licensed under the GNU General Public License, version 2")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Text("App Sandbox: \(appSandboxStatus)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.bottom, 4)
        }
        .padding(24)
        .frame(width: 300)
        .background(Color.appBackground)
    }
}
