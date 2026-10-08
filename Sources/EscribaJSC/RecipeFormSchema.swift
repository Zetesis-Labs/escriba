import Foundation
import JavaScriptCore
import EscribaCore
import EscribaEngine

public func recipeFormSchema(_ package: RecipePackage, lists: RecipeLists, timeLimit: Double = 2) throws -> String? {
    try timeLimitWorks.get()
    guard let setLimit = executionTimeLimit(), let context = JSContext(virtualMachine: JSVirtualMachine()) else {
        throw RecipeError.unavailable("JavaScriptCore no arranca")
    }
    let sourceMap = package.sourceMap.flatMap(SourceMap.init(json:))
    nonisolated(unsafe) var failure: String?
    context.exceptionHandler = { _, value in failure = describe(value, sourceMap: sourceMap) }
    setLimit(JSContextGetGroup(context.jsGlobalContextRef), timeLimit, { _, _ in true }, nil)

    context.evaluateScript(package.source, withSourceURL: URL(string: "receta://\(package.key).js"))
    if let failure { throw loadFailure(failure, timeLimit: timeLimit) }
    let problem = context.evaluateScript(
        "\(packageProblemFunction)(globalThis.__receta)", withSourceURL: URL(string: "escriba://formulario.js"))
    if let problem = problem?.toString(), !problem.isEmpty, failure == nil {
        throw RecipeError.invalidPackage(problem)
    }

    let json = try recipeJSON(lists)
    let reply = context.evaluateScript(formSource, withSourceURL: URL(string: "escriba://formulario.js"))?
        .call(withArguments: [json])
    if let failure {
        throw failure.contains("terminated") ? RecipeError.timedOut(timeLimit) : RecipeError.failed(failure)
    }
    guard let reply, !reply.isNull, !reply.isUndefined else { return nil }
    return reply.toString()
}

private func loadFailure(_ failure: String, timeLimit: Double) -> RecipeError {
    failure.contains("terminated") ? .timedOut(timeLimit) : .invalidPackage(failure)
}
