import Foundation

public enum LegacyMigration {
    public static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        move(
            home.appending(path: "Library/Application Support/jpr-transcribe"),
            to: home.appending(path: "Library/Application Support/escriba"))
        move(
            home.appending(path: ".local/state/jpr-transcribe"),
            to: home.appending(path: ".local/state/escriba"))
    }

    private static func move(_ old: URL, to new: URL) {
        let files = FileManager.default
        guard files.fileExists(atPath: old.path(percentEncoded: false)),
              !files.fileExists(atPath: new.path(percentEncoded: false))
        else { return }

        do {
            try files.createDirectory(
                at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try files.moveItem(at: old, to: new)
            Log.info("migrado \(old.lastPathComponent) a \(new.path(percentEncoded: false))")
        } catch {
            Log.error("no se pudo migrar \(old.path(percentEncoded: false)): \(error)")
        }
    }
}
