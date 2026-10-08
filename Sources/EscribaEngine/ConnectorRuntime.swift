import EscribaCore

public struct ConnectorBridge: Sendable {
    public var call: @Sendable (String) async throws -> String
    public init(call: @escaping @Sendable (String) async throws -> String) { self.call = call }
}

public struct ConnectorRuntime: Sendable {
    public var execute: @Sendable (ConnectorProgram, String, ConnectorBridge) async throws -> String
    public init(execute: @escaping @Sendable (ConnectorProgram, String, ConnectorBridge) async throws -> String) {
        self.execute = execute
    }
}
