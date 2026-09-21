import Foundation
import Security
import Synchronization

nonisolated public struct TokenStore: Sendable {
    public var read: @Sendable () -> String?
    public var write: @Sendable (String?) -> Void

    public init(
        read: @escaping @Sendable () -> String?, write: @escaping @Sendable (String?) -> Void
    ) {
        self.read = read
        self.write = write
    }

    public static func inMemory(_ initial: String? = nil) -> TokenStore {
        let box = Mutex<String?>(initial)
        return TokenStore(
            read: { box.withLock { $0 } },
            write: { value in box.withLock { $0 = value } })
    }
}

nonisolated public func defaultTokenStore(account: String) -> TokenStore {
    migratingTokenStore(
        primary: fileTokenStore(account: account),
        legacy: keychainTokenStore(account: account))
}

nonisolated public func fileTokenStore(
    directory: URL = defaultSecretsDirectory, account: String
) -> TokenStore {
    let file = directory.appending(path: "\(account).token")
    return TokenStore(
        read: {
            guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false))
            else { return nil }
            let token = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        },
        write: { value in
            let files = FileManager.default
            guard let value, !value.isEmpty else {
                try? files.removeItem(at: file)
                return
            }
            try? files.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            files.createFile(
                atPath: file.path(percentEncoded: false), contents: Data(value.utf8),
                attributes: [.posixPermissions: 0o600])
        })
}

nonisolated public var defaultSecretsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/escriba/secrets")
}

nonisolated public func migratingTokenStore(primary: TokenStore, legacy: TokenStore) -> TokenStore {
    TokenStore(
        read: {
            if let current = primary.read() { return current }
            guard let inherited = legacy.read() else { return nil }
            primary.write(inherited)
            legacy.write(nil)
            return inherited
        },
        write: { value in
            primary.write(value)
            legacy.write(nil)
        })
}

nonisolated public func keychainTokenStore(
    service: String = "dev.ruben.escriba.notion", account: String = "token"
) -> TokenStore {
    TokenStore(
        read: {
            var query = baseQuery(service: service, account: account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                let data = item as? Data
            else { return nil }
            return String(data: data, encoding: .utf8)
        },
        write: { value in
            let query = baseQuery(service: service, account: account)
            SecItemDelete(query as CFDictionary)

            guard let value, !value.isEmpty else { return }
            var item = query
            item[kSecValueData as String] = Data(value.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(item as CFDictionary, nil)
        })
}

nonisolated private func baseQuery(service: String, account: String) -> [String: Any] {
    [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: account,
    ]
}
