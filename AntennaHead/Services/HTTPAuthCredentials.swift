import Foundation
import Observation
import Security

@MainActor
@Observable
final class HTTPAuthCredentials {
    struct Credentials: Equatable, Sendable {
        let user: String
        let password: String
        let realm: String
    }

    enum AuthError: Error, CustomStringConvertible {
        case emptyUser
        case emptyPassword
        case colonInUser
        case emptyRealm
        case keychainSaveFailed(OSStatus)
        case keychainReadFailed(OSStatus)

        var description: String {
            switch self {
            case .emptyUser: return "Username must not be empty."
            case .emptyPassword: return "Password must not be empty."
            case .colonInUser: return "Username must not contain ':' (HTTP Basic auth)."
            case .emptyRealm: return "Realm must not be empty."
            case .keychainSaveFailed(let s): return "Keychain save failed: OSStatus \(s)"
            case .keychainReadFailed(let s): return "Keychain read failed: OSStatus \(s)"
            }
        }
    }

    /// Single source of truth for the realm string advertised by both the
    /// AntennaHead HTTP server and the LiveAudioServer subprocess. Matching
    /// realm strings let browsers reuse cached credentials across origins.
    static let defaultRealm = "AntennaHead"

    static let didChangeNotification = Notification.Name("AntennaHeadAuthCredentialsChanged")

    private static let enabledKey = "AntennaHead.httpAuth.enabled"
    private static let usernameKey = "AntennaHead.httpAuth.username"
    private static let realmKey = "AntennaHead.httpAuth.realm"
    private static let keychainService = "com.dsward.AntennaHead.httpAuth"

    private(set) var current: Credentials?
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey) }
    }

    init() {
        let defaults = UserDefaults.standard
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
        self.current = Self.load()
    }

    func save(user: String, password: String, realm: String) throws {
        let trimmedUser = user.trimmingCharacters(in: .whitespaces)
        let trimmedRealm = realm.trimmingCharacters(in: .whitespaces)
        guard !trimmedUser.isEmpty else { throw AuthError.emptyUser }
        guard !password.isEmpty else { throw AuthError.emptyPassword }
        guard !trimmedRealm.isEmpty else { throw AuthError.emptyRealm }
        guard !trimmedUser.contains(":") else { throw AuthError.colonInUser }

        try Self.writeKeychain(account: trimmedUser, password: password)

        let defaults = UserDefaults.standard
        defaults.set(trimmedUser, forKey: Self.usernameKey)
        defaults.set(trimmedRealm, forKey: Self.realmKey)
        defaults.set(true, forKey: Self.enabledKey)

        self.isEnabled = true
        self.current = Credentials(user: trimmedUser, password: password, realm: trimmedRealm)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func disable() {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: Self.usernameKey), !existing.isEmpty {
            Self.deleteKeychain(account: existing)
        }
        defaults.removeObject(forKey: Self.usernameKey)
        defaults.removeObject(forKey: Self.realmKey)
        defaults.set(false, forKey: Self.enabledKey)

        self.isEnabled = false
        self.current = nil
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Active credentials if and only if the user has opted in AND a usable
    /// triple is present. Servers should treat `nil` as "do not challenge".
    var effective: Credentials? {
        isEnabled ? current : nil
    }

    // MARK: - Persistence

    private static func load() -> Credentials? {
        let defaults = UserDefaults.standard
        guard let user = defaults.string(forKey: usernameKey), !user.isEmpty else { return nil }
        let realm = defaults.string(forKey: realmKey) ?? defaultRealm
        guard let password = try? readKeychain(account: user) else { return nil }
        return Credentials(user: user, password: password, realm: realm)
    }

    private static func keychainQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func writeKeychain(account: String, password: String) throws {
        let passwordData = Data(password.utf8)
        var query = keychainQuery(account: account)

        // Replace any older entries for the same or different accounts under
        // this service so we never accumulate stale credentials.
        let purge: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(purge as CFDictionary)

        query[kSecValueData as String] = passwordData
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw AuthError.keychainSaveFailed(status)
        }
    }

    private static func readKeychain(account: String) throws -> String {
        var query = keychainQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            throw AuthError.keychainReadFailed(status)
        }
        guard status == errSecSuccess, let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
            throw AuthError.keychainReadFailed(status)
        }
        return password
    }

    @discardableResult
    private static func deleteKeychain(account: String) -> OSStatus {
        SecItemDelete(keychainQuery(account: account) as CFDictionary)
    }
}
