import Foundation

public struct ConnectorProgram: Codable, Sendable, Equatable {
    public let source: String
    public let fingerprint: String
    public init(source: String, fingerprint: String) {
        self.source = source
        self.fingerprint = fingerprint
    }
}

public func validConnectorRelativePath(_ path: String) -> Bool {
    !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0")
        && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0 != "." && $0 != ".."
        }
}

public struct ConnectorPublicationRecord: Codable, Sendable, Equatable {
    public var programFingerprint: String
    public var configJSON: String
    public var receiptJSON: String?
    public var state: String
    public var locator: String?
    public var url: String?
    public init(programFingerprint: String, configJSON: String, receiptJSON: String? = nil,
                state: String, locator: String? = nil, url: String? = nil) {
        self.programFingerprint = programFingerprint
        self.configJSON = configJSON
        self.receiptJSON = receiptJSON
        self.state = state
        self.locator = locator
        self.url = url
    }
}
