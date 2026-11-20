import Foundation
import Security
import LocalAuthentication

@MainActor enum KeychainStore {
    case openAI, krisp
    private var service: String {
        switch self {
        case .openAI: return "com.evoai.atmos.openai"
        case .krisp: return "com.evoai.atmos.krisp"
        }
    }

    private var readServices: [String] {
        self == .openAI ? [service, "com.chosen.mac.openai"] : [service]
    }

    private func query(for service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "api-key"]
    }

    func save(_ key: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let valid = self == .openAI ? key.hasPrefix("sk-") && key.count > 30 : !key.isEmpty && !key.contains(where: { $0.isWhitespace })
        guard valid else {
            let message = self == .openAI ? "Enter an OpenAI API key." : "Enter a Krisp developer API key."
            throw NSError(domain: "Atmos", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        let query = query(for: service)
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
            // recreate only Atmos's exact item, using the newly supplied key.
            // No existing secret is needed, and the default ACL trusts this build.
            let deleteStatus = SecItemDelete(query as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw failure(deleteStatus)
            }
            try add(key)
            try verifySavedKey(key)
        }
    }
    private func add(_ key: String) throws {
        var item = query(for: service)
        item[kSecValueData as String] = Data(key.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
    }
    private func verifySavedKey(_ key: String) throws {
        guard try load() == key else {
            throw NSError(domain: "Atmos", code: 2, userInfo: [NSLocalizedDescriptionKey: "The saved API key could not be verified. Reconnect through Atmos Settings."])
        }
    }
    func load() throws -> String? {
        try withoutReadInteraction {
            try readData(interactive: false).flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    func exists() -> Bool {
        (try? withoutReadInteraction {
            for service in readServices {
                var request = query(for: service)
                request[kSecReturnAttributes as String] = true
                let context = LAContext()
                context.interactionNotAllowed = true
                request[kSecUseAuthenticationContext as String] = context
                let status = SecItemCopyMatching(request as CFDictionary, nil)
                if status != errSecItemNotFound {
                    return status == errSecSuccess || requiresAuthorization(status)
                }
            }
            return false
        }) ?? false
    }

    /// Interactive reads are reserved for the user's Reconnect action.
    func authorizeSavedKey() throws {
        guard let data = try readData(interactive: true), !data.isEmpty else {
            throw NSError(domain: "Atmos", code: 2, userInfo: [NSLocalizedDescriptionKey: "Add an API key in Atmos Settings."])
        }
    }

    private func readData(interactive: Bool) throws -> Data? {
        for service in readServices {
            var request = query(for: service)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            if !interactive {
                let context = LAContext()
                context.interactionNotAllowed = true
                request[kSecUseAuthenticationContext as String] = context
            }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(request as CFDictionary, &result)
            if status == errSecItemNotFound { continue }
            guard status == errSecSuccess else { throw readFailure(status) }
            return result as? Data
        }
        return nil
    }

    private func withoutReadInteraction<T>(_ operation: () throws -> T) throws -> T {
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
    private func requiresAuthorization(_ status: OSStatus) -> Bool {
        switch status {
        case errSecInteractionNotAllowed, errSecInteractionRequired, errSecAuthFailed, errSecUserCanceled: return true
        default: return false
        }
    }
    private func readFailure(_ status: OSStatus) -> NSError {
        if requiresAuthorization(status) {
            return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Reconnect the saved API key in Atmos Settings to authorize this updated build, or enter a new key."])
        }
        return failure(status)
    }
    private func failure(_ status: OSStatus) -> NSError {
        NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? String(status))"])
    }
}
