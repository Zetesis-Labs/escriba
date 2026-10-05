import Foundation

public func remoteURLProblem(_ raw: String) -> String? {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return "Escribe la URL de la API." }
    guard let components = URLComponents(string: text),
        let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
        let host = components.host, !host.isEmpty
    else { return "La URL tiene que empezar por http:// o https://." }
    guard components.user == nil, components.password == nil, components.query == nil,
        components.fragment == nil
    else { return "La URL no puede llevar usuario, contraseña ni parámetros." }
    guard scheme == "https" || isPrivateHost(host) else {
        return "Usa https:// para un servicio fuera de tu red."
    }
    return nil
}

func isPrivateHost(_ raw: String) -> Bool {
    let host = raw.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if host == "localhost" || host.hasSuffix(".local") || host == "::1" { return true }
    if host.hasPrefix("fc") || host.hasPrefix("fd") { return host.contains(":") }
    let octets = host.split(separator: ".").compactMap { Int($0) }
    guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
    switch (octets[0], octets[1]) {
    case (127, _), (10, _), (192, 168): return true
    case (172, 16...31): return true
    case (100, 64...127): return true
    default: return false
    }
}
