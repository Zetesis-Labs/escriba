import EscribaPluginKit

@_expose(wasm, "escriba_handle")
@_cdecl("escriba_handle")
func escribaHandle(_ count: Int32) -> Int32 {
    handle(count, serve)
}
