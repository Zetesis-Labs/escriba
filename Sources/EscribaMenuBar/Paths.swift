import Foundation

enum Paths {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static var defaultOutput: URL {
        home.appending(path: "Documents/Transcripciones JPR")
    }

    static var defaultState: URL {
        home.appending(path: ".local/state/escriba/ledger.db")
    }

    static var defaultLibrary: URL {
        home.appending(path: "Library/Application Support/escriba/library")
    }

    static var lockFile: URL {
        home.appending(path: ".local/state/escriba/instance.lock")
    }

    static var logFile: URL {
        home.appending(path: "Library/Logs/escriba.log")
    }
}
