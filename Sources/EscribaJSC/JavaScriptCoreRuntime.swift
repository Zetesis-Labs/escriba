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

let timeLimitWorks: Result<Void, RecipeError> = {
    setenv("JSC_usePollingTraps", "true", 0)
    guard let setLimit = executionTimeLimit() else {
        return .failure(.unavailable("esta versión de macOS no deja poner un tiempo límite a JavaScriptCore"))
    }
    guard let context = JSContext(virtualMachine: JSVirtualMachine()) else {
        return .failure(.unavailable("JavaScriptCore no arranca"))
    }
    var cut = false
    context.exceptionHandler = { _, exception in
        cut = exception?.toString()?.contains("terminated") == true
    }
    setLimit(JSContextGetGroup(context.jsGlobalContextRef), 0.05, { _, _ in true }, nil)
    context.evaluateScript("(() => { const start = Date.now(); while (Date.now() - start < 1000) {} })()")
    return cut ? .success(()) : .failure(.unavailable("el tiempo límite de JavaScriptCore no corta un bucle"))
}()

public func javaScriptCoreRuntime(timeLimit: Double = 10) throws -> RecipeRuntime {
    try timeLimitWorks.get()
    return RecipeRuntime(name: "JavaScriptCore") { package, bridge in
        try await RecipeRun(package: package, bridge: bridge, timeLimit: timeLimit).execute()
    }
}
