import Foundation
import Network
import Security
import X509
import Crypto
import SwiftASN1
import LiveAudioServerCore

@MainActor
@Observable
final class TLSCertificateManager {
    enum CertError: Error, CustomStringConvertible {
        case keyCreationFailed(String)
        case keychainAddFailed(OSStatus)
        case keychainQueryFailed(OSStatus)
        case identityWrapFailed
        case userCertLoadFailed(String)
        case certificateBuildFailed(String)
        case pkcs12ExportFailed(OSStatus)
        case applicationSupportUnavailable

        var description: String {
            switch self {
            case .keyCreationFailed(let m): return "TLS key creation failed: \(m)"
            case .keychainAddFailed(let s): return "Keychain add failed: OSStatus \(s)"
            case .keychainQueryFailed(let s): return "Keychain query failed: OSStatus \(s)"
            case .identityWrapFailed: return "Failed to wrap SecIdentity for Network.framework"
            case .userCertLoadFailed(let m): return "User certificate load failed: \(m)"
            case .certificateBuildFailed(let m): return "Self-signed certificate build failed: \(m)"
            case .pkcs12ExportFailed(let s): return "PKCS#12 export failed: OSStatus \(s)"
            case .applicationSupportUnavailable: return "Application Support directory unavailable"
            }
        }
    }

    struct ExportedIdentity {
        let url: URL
        let password: String
    }

    private let certLabel = "AntennaHead TLS Identity"
    private let keyApplicationTag = "com.dsward.AntennaHead.tlsKey"
    private static let httpsEnabledKey = "AntennaHead.httpsEnabled"

    private(set) var identity: sec_identity_t?
    private(set) var lastError: Error?

    /// Whether to start HTTPS listeners. The certificate is retained when false
    /// so it can be re-enabled without regenerating.
    var isHTTPSEnabled: Bool = UserDefaults.standard.object(forKey: httpsEnabledKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isHTTPSEnabled, forKey: Self.httpsEnabledKey) }
    }

    /// Returns the in-memory identity, loading or generating one if needed.
    func currentIdentity() throws -> sec_identity_t {
        if let identity { return identity }
        let id = try loadOrGenerate()
        identity = id
        return id
    }

    /// Discards any cached identity and forces a fresh self-signed cert.
    @discardableResult
    func regenerate() throws -> sec_identity_t {
        try deleteExisting()
        if let url = try? pkcs12FileURL() {
            try? FileManager.default.removeItem(at: url)
        }
        let id = try generateAndStore()
        identity = id
        return id
    }

    /// Loads a user-supplied PKCS#12 file (used when the user opts out of
    /// auto-generated certs in the settings UI).
    @discardableResult
    func loadUserCertificate(p12Path: String, password: String?) throws -> sec_identity_t {
        do {
            let id = try loadTLSIdentity(p12Path: p12Path, password: password)
            identity = id
            return id
        } catch {
            throw CertError.userCertLoadFailed("\(error)")
        }
    }

    /// Returns the URL and password of the PKCS#12 file written at
    /// cert-generation time. A subprocess (e.g. a LiveAudioServer CLI launched
    /// via NSTask) can load the same cert via its `--tls-identity` argument.
    func exportedIdentity() throws -> ExportedIdentity {
        _ = try currentIdentity()
        let url = try pkcs12FileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            // Regenerating writes the .p12 alongside the keychain identity.
            _ = try regenerate()
            return ExportedIdentity(url: url, password: exportPassword())
        }
        return ExportedIdentity(url: url, password: exportPassword())
    }

    /// Forces a fresh cert + PKCS#12. The `.p12` is written from the freshly
    /// generated in-memory key, so it always matches the keychain identity.
    @discardableResult
    func reexportIdentity() throws -> ExportedIdentity {
        _ = try regenerate()
        return ExportedIdentity(url: try pkcs12FileURL(), password: exportPassword())
    }

    /// Diagnostic: runs `SecPKCS12Import` on the exported `.p12` and reports
    /// what keys appear in the returned items dictionary. Helpful when the
    /// import "succeeds" but no identity entry is produced.
    func diagnosePKCS12() throws -> String {
        let url = try pkcs12FileURL()
        let data = try Data(contentsOf: url)
        let options: [String: Any] = [kSecImportExportPassphrase as String: exportPassword()]
        var items: CFArray?
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        var report = "SecPKCS12Import OSStatus: \(status)\n"
        report += "File size: \(data.count) bytes\n"
        if let array = items as? [[String: Any]] {
            report += "Items count: \(array.count)\n"
            for (i, entry) in array.enumerated() {
                report += "Entry \(i) keys: \(entry.keys.map { $0 as String }.sorted())\n"
            }
        } else {
            report += "Items array could not be cast to [[String: Any]]\n"
        }
        return report
    }

    private func pkcs12FileURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("AntennaHead", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("identity.p12")
    }

    private func exportPassword() -> String {
        let key = "AntennaHead.tlsIdentity.password"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let new = Data(bytes).base64EncodedString().replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(new, forKey: key)
        return new
    }

    private func loadOrGenerate() throws -> sec_identity_t {
        if let existing = try queryIdentity() {
            return existing
        }
        return try generateAndStore()
    }

    private func queryIdentity() throws -> sec_identity_t? {
        guard let secIdentity = try lookupRawIdentity() else { return nil }
        guard let netID = sec_identity_create(secIdentity) else {
            throw CertError.identityWrapFailed
        }
        return netID
    }

    /// Looks up our cert by label, then builds a `SecIdentity` by pairing it
    /// with its private key. We can't query `kSecClassIdentity` directly with
    /// `kSecAttrLabel` because the system matches loosely and returns the
    /// first identity in the keychain (which on a developer machine is often
    /// a stale Mac Developer cert).
    private func lookupRawIdentity() throws -> SecIdentity? {
        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        var certItem: CFTypeRef?
        let status = SecItemCopyMatching(certQuery as CFDictionary, &certItem)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CertError.keychainQueryFailed(status)
        }
        let secCert = certItem as! SecCertificate

        var identity: SecIdentity?
        let idStatus = SecIdentityCreateWithCertificate(nil, secCert, &identity)
        guard idStatus == errSecSuccess, let id = identity else {
            throw CertError.identityWrapFailed
        }
        return id
    }

    private func deleteExisting() throws {
        let identityQuery: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: certLabel,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(identityQuery as CFDictionary)

        let certQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: certLabel,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(certQuery as CFDictionary)

        let keyQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(keyApplicationTag.utf8),
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(keyQuery as CFDictionary)
    }

    private func generateAndStore() throws -> sec_identity_t {
        let swiftKey = P256.Signing.PrivateKey()
        let certKey = Certificate.PrivateKey(swiftKey)

        let bonjourName = ProcessInfo.processInfo.hostName.isEmpty
            ? "antennahead.local"
            : ProcessInfo.processInfo.hostName

        let subject: DistinguishedName
        do {
            subject = try DistinguishedName {
                CommonName("AntennaHead Self-Signed")
                OrganizationName("AntennaHead")
            }
        } catch {
            throw CertError.certificateBuildFailed("subject DN: \(error)")
        }

        let now = Date()
        let notAfter = now.addingTimeInterval(5 * 365 * 24 * 3600)

        let sanItems: [GeneralName] = [
            .dnsName("localhost"),
            .dnsName(bonjourName),
            .dnsName("*.local"),
            .ipAddress(ASN1OctetString(contentBytes: [127, 0, 0, 1]))
        ]

        let cert: Certificate
        do {
            cert = try Certificate(
                version: .v3,
                serialNumber: Certificate.SerialNumber(),
                publicKey: certKey.publicKey,
                notValidBefore: now,
                notValidAfter: notAfter,
                issuer: subject,
                subject: subject,
                signatureAlgorithm: .ecdsaWithSHA256,
                extensions: try Certificate.Extensions {
                    Critical(BasicConstraints.notCertificateAuthority)
                    KeyUsage(digitalSignature: true, keyEncipherment: true)
                    try ExtendedKeyUsage([.serverAuth])
                    SubjectAlternativeNames(sanItems)
                },
                issuerPrivateKey: certKey
            )
        } catch {
            throw CertError.certificateBuildFailed("\(error)")
        }

        var serializer = DER.Serializer()
        do {
            try serializer.serialize(cert)
        } catch {
            throw CertError.certificateBuildFailed("DER serialize: \(error)")
        }
        let certDERBytes = serializer.serializedBytes
        let certDER = Data(certDERBytes)

        guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw CertError.certificateBuildFailed("SecCertificateCreateWithData returned nil")
        }

        // Write the PKCS#12 file now while we still have the raw key in memory.
        // `SecItemExport` doesn't reliably work with data-protection keychain
        // items, so we build the PFX ourselves from cert DER + PKCS#8 key.
        let keyPKCS8 = Array(swiftKey.derRepresentation)
        let password = exportPassword()
        let p12Bytes = PKCS12Writer.build(certDER: certDERBytes,
                                          keyPKCS8: keyPKCS8,
                                          password: password)
        do {
            let url = try pkcs12FileURL()
            try Data(p12Bytes).write(to: url, options: .atomic)
        } catch {
            throw CertError.certificateBuildFailed("write .p12: \(error)")
        }

        let x963 = swiftKey.x963Representation
        let keyAttrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 256
        ]
        var keyError: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(x963 as CFData, keyAttrs as CFDictionary, &keyError) else {
            let message = keyError?.takeRetainedValue().localizedDescription ?? "SecKeyCreateWithData returned nil"
            throw CertError.keyCreationFailed(message)
        }

        try deleteExisting()

        let keyAdd: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrApplicationTag as String: Data(keyApplicationTag.utf8),
            kSecValueRef as String: secKey,
            kSecUseDataProtectionKeychain as String: true
        ]
        let keyStatus = SecItemAdd(keyAdd as CFDictionary, nil)
        guard keyStatus == errSecSuccess else {
            throw CertError.keychainAddFailed(keyStatus)
        }

        let certAdd: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: secCert,
            kSecAttrLabel as String: certLabel,
            kSecUseDataProtectionKeychain as String: true
        ]
        let certStatus = SecItemAdd(certAdd as CFDictionary, nil)
        guard certStatus == errSecSuccess else {
            throw CertError.keychainAddFailed(certStatus)
        }

        guard let id = try queryIdentity() else {
            throw CertError.identityWrapFailed
        }
        return id
    }
}
