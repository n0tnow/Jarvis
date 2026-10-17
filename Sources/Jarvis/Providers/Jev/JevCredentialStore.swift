import Foundation
import Security

// MARK: - The ONE place a provider credential lives (DEC-275, narrow exception to "never handle credentials")
//
// The TypeSafe/Jev API key is stored ONLY in the macOS Keychain (a generic password item, service `dev.jarvis.provider.typesafe-jev`). It is entered by the user through a hidden terminal prompt
// (`Jarvis --store-jev-credential`) or not at all. This file is the only code that reads it, and the only reader of the value is `TypeSafeJevTransport` at request time, as the HTTP Authorization header.
// The secret is never logged, never put in SQLite / UserDefaults / a file / a prompt / an audit event / a crash report, never shown after entry, never given to any other provider, and is not
// available to the classifier as text (it only ever sees the minimised utterance). Presence checks do not read the secret.

enum JevCredentialStore {
    static let service = "dev.jarvis.provider.typesafe-jev"
    static let account = "api-key"

    private static var base: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }

    /// Is a credential stored? Attribute-only query: the secret is not read and no access prompt is shown.
    static func isPresent() -> Bool {
        var q = base
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnAttributes as String] = true
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    /// The secret, for the transport only. nil when absent, denied or unreadable.
    static func read() -> String? {
        var q = base
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecReturnData as String] = true
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    enum StoreError: Error, Equatable { case invalid, keychain(Int32) }

    /// A plausible key: 8…512 printable characters, no whitespace.
    static func validate(_ secret: String) -> String? {
        let s = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...512).contains(s.count), !s.contains(where: { $0.isWhitespace || $0.isNewline }), s.unicodeScalars.allSatisfy({ $0.value >= 0x21 && $0.value < 0x7F }) else { return nil }
        return s
    }

    static func store(_ secret: String) -> Result<Void, StoreError> {
        guard let s = validate(secret), let data = s.data(using: .utf8) else { return .failure(.invalid) }
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return .success(()) }
        guard status == errSecItemNotFound else { return .failure(.keychain(status)) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "JARVIS · TypeSafe Jev API key"
        let added = SecItemAdd(add as CFDictionary, nil)
        return added == errSecSuccess ? .success(()) : .failure(.keychain(added))
    }

    static func delete() { SecItemDelete(base as CFDictionary) }
}
