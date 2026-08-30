import Foundation

enum Paths {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var defaultRoot: URL {
        home.appending(
            path: "Library/Mobile Documents/iCloud~com~openplanetsoftware~just-press-record/Documents"
        )
    }

    static var defaultOutput: URL {
        home.appending(path: "Documents/Transcripciones JPR")
    }

    static var defaultState: URL {
        home.appending(path: ".local/state/jpr-transcribe/ledger.db")
    }

    static var defaultLibrary: URL {
        home.appending(path: "Library/Application Support/jpr-transcribe/library")
    }

    static var lockFile: URL {
        home.appending(path: ".local/state/jpr-transcribe/instance.lock")
    }

    static var logFile: URL {
        home.appending(path: "Library/Logs/jpr-transcribe.log")
    }
}
