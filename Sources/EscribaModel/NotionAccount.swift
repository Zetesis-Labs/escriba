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
