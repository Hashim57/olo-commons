import CryptoKit
import Foundation
import Security

/// Private chats on this Mac: encrypted with AES-GCM (CryptoKit) under a 256-bit key that is
/// made once and kept in the Keychain. Nothing here ever leaves the Mac.
public enum PrivateCrypto {
    /// "OLOP" plus a format byte, before nonce + ciphertext + tag (AES.GCM's combined form).
    static let magic = Data("OLOP".utf8) + Data([1])

    public enum Failure: Error, Equatable {
        case notPrivateData
        case sealFailed
    }

    public static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        // combined is Optional: it is nil only for a nonce that is not the standard 12 bytes.
        guard let combined = box.combined else { throw Failure.sealFailed }
        return magic + combined
    }

    /// Opens what seal produced. Any change to the bytes, or the wrong key, throws.
    public static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        guard sealed.count > magic.count, sealed.prefix(magic.count) == magic else { throw Failure.notPrivateData }
        let box = try AES.GCM.SealedBox(combined: Data(sealed.dropFirst(magic.count)))
        return try AES.GCM.open(box, using: key)
    }
}

/// The private chat key in the Keychain: a generic password, service
/// io.helius-olo.desktop.private, readable after first unlock on this device only (it is
/// never synced or restored to another Mac).
public enum PrivateKeychain {
    public static let service = "io.helius-olo.desktop.private"
    public static let account = "private-chats-key"

    public struct Failure: Error, Equatable, LocalizedError {
        public var status: OSStatus
        public var errorDescription: String? { "The Keychain refused the private chat key (\(status))." }
    }

    private static func baseQuery(dataProtection: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if dataProtection { q[kSecUseDataProtectionKeychain as String] = true }
        return q
    }

    /// The key, made and saved the first time when `create` is true. nil when there is none and
    /// `create` is false.
    public static func key(create: Bool) throws -> SymmetricKey? {
        // The data protection keychain honours "this device only"; an unsigned development build
        // lacks the entitlement for it (errSecMissingEntitlement), so the login keychain is the fallback.
        for dataProtection in [true, false] {
            var q = baseQuery(dataProtection: dataProtection)
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: AnyObject?
            let status: OSStatus = SecItemCopyMatching(q as CFDictionary, &out)
            if status == errSecSuccess, let data = out as? Data, data.count == 32 { return SymmetricKey(data: data) }
            if status == errSecItemNotFound || status == errSecMissingEntitlement { continue }
            if status != errSecSuccess { throw Failure(status: status) }
        }
        guard create else { return nil }
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        var lastStatus: OSStatus = errSecSuccess
        for dataProtection in [true, false] {
            var add = baseQuery(dataProtection: dataProtection)
            add[kSecValueData as String] = bytes
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrLabel as String] = "Olo private chats"
            let added: OSStatus = SecItemAdd(add as CFDictionary, nil)
            if added == errSecSuccess { return key }
            lastStatus = added
            if added == errSecMissingEntitlement { continue }
            break
        }
        throw Failure(status: lastStatus)
    }
}

/// Private conversations as one encrypted file in Olo's container. The key is injected, so
/// tests use their own and never touch the Keychain.
public final class PrivateStore: @unchecked Sendable {
    public let fileURL: URL
    private let key: SymmetricKey
    private let queue = DispatchQueue(label: "olo.privatestore")

    public init(root: URL, key: SymmetricKey) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        self.fileURL = root.appendingPathComponent("private-chats.olop")
        self.key = key
    }

    /// The store in Application Support with the Keychain key. With `createKey` false and no key
    /// saved yet, nil: nothing private has been kept on this Mac.
    public static func appSupport(createKey: Bool) throws -> PrivateStore? {
        guard let key = try PrivateKeychain.key(create: createKey) else { return nil }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return PrivateStore(root: base.appendingPathComponent("Olo", isDirectory: true), key: key)
    }

    /// Every private conversation; empty when there is no file yet. Throws when the file cannot be
    /// opened with this key (changed on disk, or another key).
    public func load() throws -> [LocalConversation] {
        try queue.sync { () throws -> [LocalConversation] in
            guard let sealed = try? Data(contentsOf: fileURL) else { return [] }
            let plain = try PrivateCrypto.open(sealed, key: key)
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return try d.decode([LocalConversation].self, from: plain).map { c in
                var c = c
                c.isPrivate = true
                return c
            }
        }
    }

    public func save(_ list: [LocalConversation]) throws {
        try queue.sync { () throws -> Void in
            let e = JSONEncoder()
            e.dateEncodingStrategy = .iso8601
            let plain = try e.encode(list.filter(\.isPrivate))
            let sealed = try PrivateCrypto.seal(plain, key: key)
            try sealed.write(to: fileURL, options: [.atomic])
        }
    }

    /// Removes the file (Settings > Account > Remove Local Data). The key stays for later chats.
    public func erase() {
        queue.sync { () -> Void in try? FileManager.default.removeItem(at: fileURL) }
    }
}
