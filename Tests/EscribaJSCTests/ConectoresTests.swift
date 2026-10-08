import Foundation
import Testing
import EscribaCore
import EscribaEngine
import EscribaJSC

@Suite("Conectores JavaScript con capacidades")
struct ConectoresTests {
    @Test("una promesa diferida conserva el resultado del puente")
    func promesaDiferida() async throws {
        let runtime = try javaScriptCoreConnectorRuntime()
        let program = ConnectorProgram(source: "var __conectores = { async run(request, host) { await new Promise(r => setTimeout(r, 5)); return await host.files.snapshot() } }", fingerprint: "prueba")
        let result = try await runtime.execute(program, "{}", ConnectorBridge { request in
            #expect(request.contains("files.snapshot"))
            try await Task.sleep(for: .milliseconds(5))
            return "{\"nota.md\":\"hola\"}"
        })
        #expect(result == "{\"nota.md\":\"hola\"}")
    }
    @Test("el fallo al guardar el recibo conserva el error del host")
    func falloDelRecibo() async throws {
        enum Fallo: Error { case disco }
        let runtime = try javaScriptCoreConnectorRuntime()
        let program = ConnectorProgram(source: "var __conectores = { async run(r,h) { await h.checkpoint({page:'123'}); return 'incorrecto' } }", fingerprint: "prueba")
        await #expect(throws: Fallo.disco) {
            _ = try await runtime.execute(program, "{}", ConnectorBridge { _ in throw Fallo.disco })
        }
    }

    @Test("una promesa que no termina agota el límite total")
    func limiteTotal() async throws {
        let runtime = try javaScriptCoreConnectorRuntime(wallTimeLimit: 0.03)
        let program = ConnectorProgram(source: "var __conectores = { run() { return new Promise(() => {}) } }", fingerprint: "prueba")
        await #expect(throws: RecipeError.timedOut(0.03)) {
            _ = try await runtime.execute(program, "{}", ConnectorBridge { _ in "null" })
        }
    }

    @Test("los identificadores del puente y las credenciales no se exponen como globals")
    func sinCredenciales() async throws {
        let runtime = try javaScriptCoreConnectorRuntime()
        let program = ConnectorProgram(source: "var __conectores = { run(r,h) { return [typeof __connectorCall,typeof fetch,typeof process,typeof require,Object.keys(h)] } }", fingerprint: "prueba")
        let result = try await runtime.execute(program, "{}", ConnectorBridge { _ in "null" })
        #expect(result == "[\"undefined\",\"undefined\",\"undefined\",\"undefined\",[\"fetch\",\"files\",\"audio\",\"checkpoint\"]]")
    }

    @Test("el paquete de serie carga el SDK oficial en JavaScriptCore")
    func paqueteReal() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "packages/conectores/dist/conectores.js")
        let source = try String(contentsOf: file, encoding: .utf8)
        let runtime = try javaScriptCoreConnectorRuntime()
        let program = ConnectorProgram(source: source, fingerprint: "serie")
        let result = try await runtime.execute(program, "{\"operation\":\"manifest\"}", ConnectorBridge { _ in
            Issue.record("el manifiesto no debe acceder al host")
            return "null"
        })
        #expect(result.contains("notion"))
        #expect(result.contains("okf"))
    }

    @Test("la inspección ejecuta el catálogo sin capacidades de red")
    func inspeccion() async throws {
        let program = ConnectorProgram(source: "var __conectores = { inspect() { return {destinations:[],network:typeof fetch,host:typeof host} } }", fingerprint: "catalogo")
        let result = try await inspectConnectorProgram(program)
        #expect(result == "{\"destinations\":[],\"network\":\"undefined\",\"host\":\"undefined\"}")
    }

    @Test("el audio opaco conserva el rango al enviarse por multipart")
    func audioPorPartes() async throws {
        let runtime = try javaScriptCoreConnectorRuntime()
        let program = ConnectorProgram(source: "var __conectores = { async run(r,h) { const audio=await h.audio();const form=new FormData();form.append('file',audio.data.slice(2,5),audio.filename);const response=await h.fetch('https://example.test/upload',{method:'POST',body:form});return response.status } }", fingerprint: "audio")
        let result = try await runtime.execute(program, "{}", ConnectorBridge { request in
            if request.contains("\"op\":\"audio\"") { return "{\"id\":\"audio\",\"filename\":\"nota.m4a\",\"contentType\":\"audio/mp4\",\"size\":8}" }
            let object = try #require(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String:Any])
            let part = try #require((object["multipart"] as? [[String:Any]])?.first)
            #expect(part["offset"] as? Int == 2)
            #expect(part["length"] as? Int == 3)
            #expect(part["attachment"] as? String == "audio")
            #expect(!request.contains("/Users/"))
            return "{\"status\":200,\"headers\":{},\"body\":\"\"}"
        })
        #expect(result == "200")
    }

    @Test("el SDK oficial descubre bases a través de fetch del host")
    func sdkRealPorElPuente() async throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appending(path: "packages/conectores/dist/conectores.js")
        let source = try String(contentsOf: file, encoding: .utf8)
        let runtime = try javaScriptCoreConnectorRuntime()
        let result = try await runtime.execute(ConnectorProgram(source: source, fingerprint: "sdk"), "{\"operation\":\"discover\",\"provider\":\"notion\"}", ConnectorBridge { request in
            #expect(request.contains("https://api.notion.com/v1/search"))
            return "{\"status\":200,\"headers\":{},\"body\":\"{\\\"object\\\":\\\"list\\\",\\\"results\\\":[],\\\"has_more\\\":false,\\\"next_cursor\\\":null}\"}"
        })
        #expect(result == "{\"resources\":[]}")
    }

    @Test("el límite de CPU interrumpe un bucle del conector")
    func limiteCPU() async throws {
        let runtime = try javaScriptCoreConnectorRuntime(timeLimit: 0.02)
        let program = ConnectorProgram(source: "var __conectores = { run() { while(true) {} } }", fingerprint: "bucle")
        await #expect(throws: RecipeError.timedOut(0.02)) {
            _ = try await runtime.execute(program,"{}",ConnectorBridge { _ in "null" })
        }
    }

    @Test("cancelar una ejecución interrumpe las tareas del puente")
    func cancelacion() async throws {
        let runtime = try javaScriptCoreConnectorRuntime()
        let program = ConnectorProgram(source: "var __conectores = { async run(r,h) { return await h.files.snapshot() } }", fingerprint: "cancelar")
        let task = Task {
            try await runtime.execute(program,"{}",ConnectorBridge { _ in
                try await Task.sleep(for: .seconds(30))
                return "{}"
            })
        }
        try await Task.sleep(for: .milliseconds(10))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

}
