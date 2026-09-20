import CWasiHttp

struct Destino { let host: String; let path: String }
let destinos = [
    Destino(host: "api.notion.com", path: "/v1/users/me"),
    Destino(host: "www.swift.org", path: "/"),
]
for destino in destinos {
    let status = escriba_fetch_status(destino.host, destino.path)
    print("GET https://\(destino.host)\(destino.path) -> \(status)")
}
