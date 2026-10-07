import Foundation

public let SF_DATALESS: UInt32 = 0x4000_0000

public struct Recording: Sendable, Hashable {
    public let url: URL
    public let startedAt: Date
    public let key: String

    public init(url: URL, startedAt: Date, key: String) {
        self.url = url
        self.startedAt = startedAt
        self.key = key
    }
}

public struct Probe: Sendable, Equatable {
    public let size: Int64
    public let blocks: Int64
    public let flags: UInt32
    public let modifiedAt: Date
    public let observedAt: Date

    public init(size: Int64, blocks: Int64, flags: UInt32, modifiedAt: Date, observedAt: Date) {
        self.size = size
        self.blocks = blocks
        self.flags = flags
        self.modifiedAt = modifiedAt
        self.observedAt = observedAt
    }

    public var isDataless: Bool { flags & SF_DATALESS != 0 }
}

public enum FileState: String, Sendable {
    case dataless
    case empty
    case growing
    case ready
    case abandoned
}
