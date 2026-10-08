import EscribaCore
import EscribaEngine

public func javaScriptCoreConnectorRuntime(timeLimit: Double = 10, wallTimeLimit: Double = 120) throws -> ConnectorRuntime {
    try timeLimitWorks.get()
    return ConnectorRuntime { program, request, bridge in
        let run = ConnectorRun(program: program, bridge: bridge, timeLimit: timeLimit, wallTimeLimit: wallTimeLimit)
        return try await withTaskCancellationHandler {
            try await run.execute(request)
        } onCancel: {
            Task { await run.cancel() }
        }
    }
}

public func inspectConnectorProgram(_ program: ConnectorProgram, timeLimit: Double = 2) async throws -> String {
    try timeLimitWorks.get()
    let bridge = ConnectorBridge { _ in throw RecipeError.failed("la inspección no tiene capacidades del host") }
    return try await ConnectorRun(program: program, bridge: bridge, timeLimit: timeLimit, wallTimeLimit: timeLimit, inspecting: true).execute("{}")
}
