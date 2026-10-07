import Darwin
import Foundation
import JavaScriptCore
import EscribaCore
import EscribaEngine

typealias ShouldTerminate = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> Bool
typealias SetExecutionTimeLimit = @convention(c) (
    OpaquePointer?, Double, ShouldTerminate?, UnsafeMutableRawPointer?
) -> Void

func executionTimeLimit() -> SetExecutionTimeLimit? {
    let everywhere = UnsafeMutableRawPointer(bitPattern: -2)
    guard let symbol = dlsym(everywhere, "JSContextGroupSetExecutionTimeLimit") else { return nil }
    return unsafeBitCast(symbol, to: SetExecutionTimeLimit.self)
}

private let pollingTraps: Void = {
    setenv("JSC_usePollingTraps", "true", 0)
}()

public func javaScriptCoreRuntime(timeLimit: Double = 10) throws -> RecipeRuntime {
    _ = pollingTraps
    guard executionTimeLimit() != nil else {
        throw RecipeError.unavailable("esta versión de macOS no deja poner un tiempo límite a JavaScriptCore")
    }
    return RecipeRuntime(name: "JavaScriptCore") { package, bridge in
        try await RecipeRun(package: package, bridge: bridge, timeLimit: timeLimit).execute()
    }
}
