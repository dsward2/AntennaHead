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

        var description: String {
            switch self {
            case .keyCreationFailed(let m): return "TLS key creation failed: \(m)"
            case .keychainAddFailed(let s): return "Keychain add failed: OSStatus \(s)"
            case .keychainQueryFailed(let s): return "Keychain query failed: OSStatus \(s)"
            case .identityWrapFailed: return "Failed to wrap SecIdentity for Network.framework"
            case .userCertLoadFailed(let m): return "User certificate load failed: \(m)"
            case .certificateBuildFailed(let m): return "Self-signed certificate build failed: \(m)"
            }
        }
    }

    private let certLabel = "AntennaHead TLS Identity"
    private let keyApplicationTag = "com.dsward.AntennaHead.tlsKey"

    private(set) var identity: sec_identity_t?
    private(set) var lastError: Error?

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

    private func loadOrGenerate() throws -> sec_identity_t {
        if let existing = try queryIdentity() {
            return existing
        }
        return try generateAndStore()
    }

    private func queryIdentity() throws -> sec_identity_t? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: certLabel,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw CertError.keychainQueryFailed(status)
        }
        let secIdentity = item as! SecIdentity
        guard let netID = sec_identity_create(secIdentity) else {
            throw CertError.identityWrapFailed
        }
        return netID
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
        let certDER = Data(serializer.serializedBytes)

        guard let secCert = SecCertificateCreateWithData(nil, certDER as CFData) else {
            throw CertError.certificateBuildFailed("SecCertificateCreateWithData returned nil")
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
