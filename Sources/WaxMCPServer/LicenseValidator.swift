#if MCPServer
import Foundation

#if canImport(Security)
import Security
#endif

// LicenseValidator is nonisolated — all access to mutable statics goes through `lock`.
// Do NOT add @MainActor here; the MCP server runs on a non-main executor and calling
// MainActor.run { } from a dispatchMain() context risks deadlocks.
enum LicenseValidator {
    private static let lock = NSLock()

    // These are mutated only from tests; production code treats them as constants.
    static var trialDefaults: UserDefaults {
        get { lock.withLock { _trialDefaults } }
        set { lock.withLock { _trialDefaults = newValue } }
    }
    static var firstLaunchKey: String {
        get { lock.withLock { _firstLaunchKey } }
        set { lock.withLock { _firstLaunchKey = newValue } }
    }
    static var keychainEnabled: Bool {
        get { lock.withLock { _keychainEnabled } }
        set { lock.withLock { _keychainEnabled = newValue } }
    }

    private static var _trialDefaults: UserDefaults = .standard
    private static var _firstLaunchKey = "wax_first_launch"
    private static var _keychainEnabled = true

    private static let keyPattern = #"^[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$"#
    private static let keyRegex = try? NSRegularExpression(pattern: keyPattern)
    private static let trialDuration: TimeInterval = 14 * 24 * 60 * 60
    private static let keychainService = "com.wax.mcpserver"
    private static let keychainAccount = "license_key"

    enum ValidationError: LocalizedError, Equatable {
        case invalidLicenseKey
        case trialExpired

        var errorDescription: String? {
            switch self {
            case .invalidLicenseKey:
                return "Invalid Wax license key. Get one at waxmcp.dev"
            case .trialExpired:
                return "Wax trial expired. Get a license at waxmcp.dev"
            }
        }
    }

    static func validate(key: String?) throws {
        if let providedKey = normalizedKey(from: key) {
            guard isValidFormat(providedKey) else {
                throw ValidationError.invalidLicenseKey
            }
            if keychainEnabled {
                saveToKeychain(providedKey)
            }
            Task.detached(priority: .background) {
                await pingActivation(key: providedKey)
            }
            return
        }

        if keychainEnabled,
           let storedKey = normalizedKey(from: readFromKeychain()),
           isValidFormat(storedKey) {
            Task.detached(priority: .background) {
                await pingActivation(key: storedKey)
            }
            return
        }

        try checkTrialPeriod()
    }

    // Validates format only (XXXX-XXXX-XXXX-XXXX with alphanumeric segments).
    // NOTE: This is intentionally client-side format validation only. It does NOT verify
    // that the key is an authentic, paid license. Server-side activation (pingActivation)
    // is a no-op placeholder and will be wired to the licensing backend in a future release.
    // Any string matching the pattern will currently pass this check.
    static func isValidFormat(_ key: String) -> Bool {
        guard let keyRegex else { return false }
        let range = NSRange(key.startIndex..<key.endIndex, in: key)
        return keyRegex.firstMatch(in: key, options: [], range: range) != nil
    }

    static func checkTrialPeriod() throws {
        let now = Date()
        if let firstLaunch = trialDefaults.object(forKey: firstLaunchKey) as? Date {
            if now.timeIntervalSince(firstLaunch) > trialDuration {
                throw ValidationError.trialExpired
            }
            return
        }

        trialDefaults.set(now, forKey: firstLaunchKey)
    }

    static func readFromKeychain() -> String? {
        #if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        guard let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
        #else
        return nil
        #endif
    }

    static func saveToKeychain(_ key: String) {
        #if canImport(Security)
        let encoded = Data(key.utf8)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
        ]
        let attrs: [String: Any] = [kSecValueData as String: encoded]

        let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }

        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = encoded
            _ = SecItemAdd(add as CFDictionary, nil)
        }
        #else
        _ = key
        #endif
    }

    // Placeholder for server-side license activation. Currently a no-op.
    // TODO: Wire to licensing backend before enforcing license gating in production.
    static func pingActivation(key: String) async {
        _ = key
    }

    private static func normalizedKey(from raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.uppercased()
    }
}
#endif
