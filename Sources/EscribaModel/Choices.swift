import Foundation
import Synchronization
import EscribaEngine

nonisolated public struct ChoiceStore: Sendable {
    public var read: @Sendable (String) -> ResolverChoice?
    public var write: @Sendable (String, ResolverChoice?) -> Void

    public init(
        read: @escaping @Sendable (String) -> ResolverChoice?,
        write: @escaping @Sendable (String, ResolverChoice?) -> Void
    ) {
        self.read = read
        self.write = write
    }

    public static func inMemory() -> ChoiceStore {
        let box = Mutex<[String: ResolverChoice]>([:])
        return ChoiceStore(
            read: { path in box.withLock { $0[choiceKey(path)] } },
            write: { path, choice in box.withLock { $0[choiceKey(path)] = choice.flatMap { $0.isEmpty ? nil : $0 } } })
    }
}

nonisolated func choiceKey(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path(percentEncoded: false)
}

nonisolated public func fileChoiceStore(_ file: URL) -> ChoiceStore {
    let cache = Mutex<[String: ResolverChoice]?>(nil)

    @Sendable func load() -> [String: ResolverChoice] {
        guard let data = FileManager.default.contents(atPath: file.path(percentEncoded: false)) else { return [:] }
        do {
            return try JSONDecoder().decode([String: ResolverChoice].self, from: data)
        } catch {
            Log.error("las elecciones guardadas no se pudieron leer y se ignoran: \(error)")
            return [:]
        }
    }

    return ChoiceStore(
        read: { path in
            cache.withLock { cached in
                if cached == nil { cached = load() }
                return cached?[choiceKey(path)]
            }
        },
        write: { path, choice in
            cache.withLock { cached in
                var all = cached ?? load()
                all[choiceKey(path)] = choice.flatMap { $0.isEmpty ? nil : $0 }
                cached = all
                do {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    try encoder.encode(all).write(to: file, options: .atomic)
                } catch {
                    Log.error("no se pudo guardar la eleccion de \(path): \(error)")
                }
            }
        })
}
