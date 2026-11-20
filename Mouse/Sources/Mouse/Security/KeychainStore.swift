import Foundation
import Security
import LocalAuthentication

@MainActor enum KeychainStore {
    // Keep the original service identifier so the rename preserves the saved key.
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.chosen.mac.openai", kSecAttrAccount as String: "api-key"] }
    static func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard key.hasPrefix("sk-"), key.count > 30 else { throw NSError(domain: "Mouse", code: 1, userInfo: [NSLocalizedDescriptionKey: "Enter an OpenAI API key."]) }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if status == errSecItemNotFound {
            try add(key)
            try verifySavedKey(key)
            return
        }
        guard status == errSecSuccess else { throw failure(status) }
        do {
            try verifySavedKey(key)
        } catch {
            let securityError = error as NSError
            guard securityError.domain == NSOSStatusErrorDomain,
                  let status = OSStatus(exactly: securityError.code),
                  requiresAuthorization(status) else { throw error }
            // Updating data preserves the old build's ACL. An explicit Save can
            // recreate only Mouse's exact item, using the newly supplied key.
            // No existing secret is needed, and the default ACL trusts this build.
            let deleteStatus = SecItemDelete(query as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw failure(deleteStatus)
            }
            try add(key)
            try verifySavedKey(key)
        }
    }
    private static func add(_ key: String) throws {
        var item = query
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }
    private static func verifySavedKey(_ key: String) throws {
        guard try load() == key else {
            throw NSError(domain: "Mouse", code: 2, userInfo: [NSLocalizedDescriptionKey: "The saved API key could not be verified. Reconnect through Mouse Settings."])
        }
    }
    static func load() throws -> String? {
        try withoutReadInteraction {
            var request = query
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw readFailure(status) }
            return (result as? Data).flatMap { String(data: $0, encoding: .utf8) }
        }
    }
    static func exists() -> Bool {
        (try? withoutReadInteraction {
            var request = query
            request[kSecReturnAttributes as String] = true
            let context = LAContext()
            context.interactionNotAllowed = true
            request[kSecUseAuthenticationContext as String] = context
            return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
        }) ?? false
    }
    /// Only called by the explicit Reconnect button. Normal reads never prompt.
    /// macOS authorizes this build to read the existing item; its ACL is not
    /// widened or replaced by the app, and the credential is never displayed.
    static func authorizeSavedKey() throws {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess else { throw readFailure(status) }
        guard let data = result as? Data, !data.isEmpty else {
            throw NSError(domain: "Mouse", code: 2, userInfo: [NSLocalizedDescriptionKey: "No saved API key was found. Add one in Mouse Settings."])
        }
    }
    private static func withoutReadInteraction<T>(_ operation: () throws -> T) throws -> T {
        // The current store is the legacy Mac keychain. Its authorization dialogs
        // need this legacy switch as well as LAContext's data-protection setting.
        // Main-actor serialization and a synchronous body keep the scope bounded.
        var previous = DarwinBoolean(false)
        let readStatus = SecKeychainGetUserInteractionAllowed(&previous)
        guard readStatus == errSecSuccess else { throw readFailure(readStatus) }
        let disableStatus = SecKeychainSetUserInteractionAllowed(false)
        guard disableStatus == errSecSuccess else { throw readFailure(disableStatus) }
        defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
        return try operation()
    }
    private static func requiresAuthorization(_ status: OSStatus) -> Bool {
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled: return true
        default: return false
        }
    }
    private static func readFailure(_ status: OSStatus) -> NSError {
        if requiresAuthorization(status) {
            return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Reconnect the saved API key in Mouse Settings to authorize this updated build, or enter a new key."])
        }
        return failure(status)
    }
    private static func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"])
    }
}
