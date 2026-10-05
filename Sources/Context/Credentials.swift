import Foundation
import Security
import LocalAuthentication
import AppKit

/// Stores secret values in the login Keychain. Workspace records only hold a `CredentialRef` (identifier and labels),
/// so secrets never appear in workspace.json, backups, search, notifications, or logs.
enum CredentialVault {
    static let service = "local.context.workspace.credential"

    private static func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString]
    }

    static func store(_ secret: String, for id: UUID) throws {
        let data = Data(secret.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(id) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(id)
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Context credential"
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw VaultError(status: status) }
    }

    static func read(_ id: UUID) throws -> String {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data, let secret = String(data: data, encoding: .utf8) else {
            throw VaultError(status: status)
        }
        return secret
    }

    static func exists(_ id: UUID) -> Bool {
        var request = query(id)
        request[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(request as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ ids: [UUID]) {
        for id in ids { SecItemDelete(query(id) as CFDictionary) }
    }

    /// Requires the Mac user's Touch ID or password before revealing or copying a secret.
    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return false }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Copies a secret and clears it from the clipboard after `seconds`, unless something else was copied meanwhile.
    @MainActor
    static func copyTemporarily(_ secret: String, seconds: Double = 45) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Mark as concealed so clipboard managers that honour the convention skip it.
        pasteboard.setString(secret, forType: .string)
        pasteboard.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let change = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
    }
}

struct VaultError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? {
        if status == errSecItemNotFound { return "This secret is not stored in this Mac's Keychain. It may have been created on another Mac or removed." }
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
        return "The Keychain could not complete this request. \(message)"
    }
}
