import SwiftUI
import UniformTypeIdentifiers

struct TLSSettingsView: View {
    @Bindable var tlsManager: TLSCertificateManager

    @State private var statusMessage: String = ""
    @State private var isError: Bool = false
    @State private var exportURL: URL?
    @State private var exportPassword: String?
    @State private var showImporter: Bool = false

    var body: some View {
        Form {
            Section("Certificate") {
                LabeledContent("Status") {
                    Text(tlsManager.identity == nil ? "Not loaded" : "Loaded")
                        .foregroundStyle(tlsManager.identity == nil ? .secondary : .green)
                }
                Button("Load / Generate Self-Signed Certificate") {
                    runResult {
                        _ = try tlsManager.currentIdentity()
                        return "Identity ready."
                    }
                }
                Button("Regenerate Self-Signed Certificate") {
                    runResult {
                        _ = try tlsManager.regenerate()
                        exportURL = nil
                        exportPassword = nil
                        return "New certificate generated."
                    }
                }
                .help("Discards the existing keychain identity and creates a fresh one. Clients will need to re-trust the new cert.")
            }

            Section("Export for Subprocess") {
                Text("Use these values to launch a LiveAudioServer subprocess with `--tls-identity <path> --tls-password <password>`.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Export PKCS#12 to Application Support") {
                    runResult {
                        let exported = try tlsManager.reexportIdentity()
                        exportURL = exported.url
                        exportPassword = exported.password
                        return "Exported to \(exported.url.path)"
                    }
                }

                if let exportURL {
                    LabeledContent("File") {
                        Text(exportURL.path)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                if let exportPassword {
                    LabeledContent("Password") {
                        Text(exportPassword)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }

            Section("User-Supplied Certificate") {
                Text("Override the auto-generated cert with a `.p12` file you provide.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Choose .p12 File…") {
                    showImporter = true
                }
            }

            if !statusMessage.isEmpty {
                Section("Last Action") {
                    Text(statusMessage)
                        .foregroundStyle(isError ? .red : .primary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("TLS / Security")
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.x509Certificate, .data]) { result in
            switch result {
            case .success(let url):
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
                runResult {
                    _ = try tlsManager.loadUserCertificate(p12Path: url.path, password: nil)
                    return "Loaded user certificate from \(url.path)"
                }
            case .failure(let error):
                statusMessage = "File picker error: \(error.localizedDescription)"
                isError = true
            }
        }
    }

    private func runResult(_ action: () throws -> String) {
        do {
            let message = try action()
            statusMessage = message
            isError = false
        } catch {
            statusMessage = "\(error)"
            isError = true
        }
    }
}
