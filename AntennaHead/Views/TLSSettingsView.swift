import SwiftUI
import UniformTypeIdentifiers

struct TLSSettingsView: View {
    @Bindable var tlsManager: TLSCertificateManager
    @Bindable var authCredentials: HTTPAuthCredentials

    @State private var statusMessage: String = ""
    @State private var isError: Bool = false
    @State private var exportURL: URL?
    @State private var exportPassword: String?
    @State private var showImporter: Bool = false
    @State private var userCertPassword: String = ""

    @State private var authUsername: String = ""
    @State private var authPassword: String = ""
    @State private var authRealm: String = HTTPAuthCredentials.defaultRealm

    var body: some View {
        Form {
            Section {
                Text("AntennaHead provides HTTP service by default. You can optionally enable HTTPS by configuring a TLS certificate, and optionally require a username and password login by enabling HTTP Authentication — both using the settings below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Certificate") {
                Toggle("Enable HTTPS", isOn: Binding(
                    get: { tlsManager.isHTTPSEnabled },
                    set: { newValue in
                        tlsManager.isHTTPSEnabled = newValue
                        NotificationCenter.default.post(
                            name: AntennaHeadHTTPServer.settingsDidChangeNotification, object: nil)
                    }
                ))
                if !tlsManager.isHTTPSEnabled {
                    Text("HTTPS is disabled. The certificate is retained and HTTPS can be re-enabled at any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Certificate Status") {
                    Text(tlsManager.identity == nil ? "Not loaded" : "Loaded")
                        .foregroundStyle(tlsManager.identity == nil ? Color.secondary : Color.green)
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
                Text("Override the auto-generated cert with a `.p12` file you provide. Leave the password blank for an unprotected file.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                SecureField("PKCS#12 Password", text: $userCertPassword)
                Button("Choose .p12 File…") {
                    showImporter = true
                }
                Button("Verify Auto-Generated .p12 Round-Trip") {
                    runResult {
                        let exported = try tlsManager.exportedIdentity()
                        _ = try tlsManager.loadUserCertificate(p12Path: exported.url.path,
                                                               password: exported.password)
                        return "Round-trip OK: \(exported.url.path)"
                    }
                }
                .help("Loads the auto-generated .p12 back through SecPKCS12Import using the exported password. Confirms the file is consumable by LiveAudioServer.")
                Button("Diagnose Exported .p12") {
                    runResult {
                        try tlsManager.diagnosePKCS12()
                    }
                }
                .help("Reports the structure of items SecPKCS12Import sees in the exported .p12.")
            }

            Section("HTTP Authentication") {
                Text("These credentials protect the AntennaHead web UI and are forwarded to the LiveAudioServer subprocess. Browsers cache credentials per port, so you may be prompted again the first time you visit each server; subsequent visits will be silent.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Toggle("Require HTTP authentication", isOn: Binding(
                    get: { authCredentials.isEnabled },
                    set: { newValue in
                        if newValue {
                            authCredentials.isEnabled = true
                        } else {
                            authCredentials.disable()
                            authUsername = ""
                            authPassword = ""
                            statusMessage = "HTTP authentication disabled."
                            isError = false
                        }
                    }
                ))

                if authCredentials.isEnabled {
                    TextField("Username", text: $authUsername)
                        .textContentType(.username)
                        .disableAutocorrection(true)
                    SecureField("Password", text: $authPassword)
                    TextField("Realm", text: $authRealm)
                        .disableAutocorrection(true)
                    Button("Apply Credentials") {
                        runResult {
                            try authCredentials.save(user: authUsername,
                                                     password: authPassword,
                                                     realm: authRealm)
                            authPassword = ""
                            return "HTTP authentication updated."
                        }
                    }
                    if let current = authCredentials.current {
                        LabeledContent("Active user") {
                            Text(current.user)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        LabeledContent("Active realm") {
                            Text(current.realm)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("No credentials saved yet — enter a username, password, and realm above and tap Apply.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
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
        .onAppear {
            if let current = authCredentials.current {
                authUsername = current.user
                authRealm = current.realm
            } else if authRealm.isEmpty {
                authRealm = HTTPAuthCredentials.defaultRealm
            }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.x509Certificate, .data]) { result in
            switch result {
            case .success(let url):
                let didStartAccess = url.startAccessingSecurityScopedResource()
                defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }
                let password = userCertPassword.isEmpty ? nil : userCertPassword
                runResult {
                    _ = try tlsManager.loadUserCertificate(p12Path: url.path, password: password)
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
