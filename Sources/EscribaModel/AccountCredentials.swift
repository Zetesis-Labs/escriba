import Foundation
import Security
import Synchronization
import EscribaEngine

nonisolated public struct TokenStore: Sendable {
    public var read: @Sendable () -> String?
    public var write: @Sendable (String?) -> Void
    public var save: @Sendable (String?) throws -> Void

    public init(
        read: @escaping @Sendable () -> String?, write: @escaping @Sendable (String?) -> Void,
        save: (@Sendable (String?) throws -> Void)? = nil
    ) {
        self.read = read
        self.write = write
        self.save = save ?? { value in write(value) }
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
    let persist: @Sendable (String?) throws -> Void = { value in
        let files = FileManager.default
        guard !account.isEmpty, !account.contains("/"), !account.contains("\\"), account != ".", account != ".." else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        guard let value, !value.isEmpty else {
            if files.fileExists(atPath: file.path) {
                guard try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory != true else { throw CocoaError(.fileWriteNoPermission) }
                try files.removeItem(at: file)
            }
            return
        }
        try files.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appending(path: ".credential-" + UUID().uuidString)
        guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? files.removeItem(at: temporary) }
        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try handle.write(contentsOf: Data(value.utf8))
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard rename(temporary.path, file.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    return TokenStore(
        read: {
            guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)) else { return nil }
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return token.isEmpty ? nil : token
        },
        write: { value in
            do { try persist(value) }
            catch { Log.error("No se pudo guardar la credencial: \(error.localizedDescription)") }
        }, save: persist)

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
            do {
                try primary.save(inherited)
                legacy.write(nil)
            } catch {
                Log.error("No se pudo migrar la credencial: \(error.localizedDescription)")
            }
            return inherited
        },
        write: { value in
            do {
                try primary.save(value)
                legacy.write(nil)
            } catch { Log.error("No se pudo guardar la credencial: \(error.localizedDescription)") }
        },
        save: { value in
            try primary.save(value)
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
