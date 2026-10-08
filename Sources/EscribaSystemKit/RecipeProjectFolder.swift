import Foundation
import EscribaCore
import EscribaEngine

public func folderRecipeProject(root: URL, installed: URL) -> RecipeProjectDisk {
    RecipeProjectDisk(
        snapshot: { try recipeProjectSnapshot(root: root) },
        write: { path, contents in
            let target = root.appending(path: path)
            try FileManager.default.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: target, atomically: true, encoding: .utf8)
        },
        loadInstalled: { try readInstalledRecipes(at: installed) },
        saveInstalled: { recipes in
            try FileManager.default.createDirectory(
                at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recipes).write(to: installed, options: .atomic)
        })
}

public func readInstalledRecipes(at installed: URL) throws -> [String: InstalledRecipe] {
    guard let data = FileManager.default.contents(atPath: installed.path(percentEncoded: false)) else { return [:] }
    return try JSONDecoder().decode([String: InstalledRecipe].self, from: data)
}

func recipeProjectSnapshot(root: URL) throws -> RecipeProjectSnapshot {
    try snapshotConnectorProject(root: root)
}

public enum ConnectorProjectSnapshotError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let message): "no se pudo capturar el proyecto: \(message)" }
    }
}

public func snapshotConnectorProject(root: URL) throws -> RecipeProjectSnapshot {
    let root = connectorCanonicalFolder(root)
    let first = try captureConnectorProject(root: root)
    let second = try captureConnectorProject(root: root)
    guard first.paths == second.paths, first.sources == second.sources else {
        throw ConnectorProjectSnapshotError.invalid("los ficheros cambiaron durante la captura; vuelve a compilar")
    }
    if first.paths.contains(where: { $0.hasPrefix("node_modules/") }),
        !["package-lock.json", "npm-shrinkwrap.json", "pnpm-lock.yaml", "yarn.lock"].contains(where: first.paths.contains)
    {
        throw ConnectorProjectSnapshotError.invalid("las dependencias instaladas necesitan un lockfile del proyecto")
    }
    return first
}

private func captureConnectorProject(root: URL) throws -> RecipeProjectSnapshot {
    guard let walker = FileManager.default.enumerator(
        at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [])
    else { throw ConnectorProjectSnapshotError.invalid("la carpeta no existe") }
    let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
    let extensions: Set<String> = ["ts", "tsx", "js", "jsx", "json", "mts", "cts", "mjs", "cjs", "yaml", "lock", "md"]
    let files = ConnectorFiles(root: root)
    var paths: Set<String> = []
    var sources: [String: String] = [:]
    var total = 0
    for case let url as URL in walker {
        guard url.path.hasPrefix(base) else { throw ConnectorProjectSnapshotError.invalid("ruta fuera de la carpeta") }
        let relative = String(url.path.dropFirst(base.count))
        if ignoredByConnectorProject(relative) {
            if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { walker.skipDescendants() }
            continue
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        if values.isSymbolicLink == true { throw ConnectorProjectSnapshotError.invalid("enlace simbólico no permitido: \(relative)") }
        guard values.isRegularFile == true else { continue }
        paths.insert(relative)
        guard paths.count <= 50_000 else { throw ConnectorProjectSnapshotError.invalid("más de 50000 ficheros") }
        guard extensions.contains(url.pathExtension) else { continue }
        guard let contents = try files.read(relative, limit: 8 * 1024 * 1024) else {
            throw ConnectorProjectSnapshotError.invalid("no se pudo leer UTF-8: \(relative)")
        }
        total += contents.utf8.count
        guard total <= 128 * 1024 * 1024 else { throw ConnectorProjectSnapshotError.invalid("más de 128 MiB de fuentes") }
        sources[relative] = contents
    }
    return RecipeProjectSnapshot(paths: paths, sources: sources)
}
