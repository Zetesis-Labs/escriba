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
        loadInstalled: {
            guard let data = FileManager.default.contents(atPath: installed.path(percentEncoded: false)) else {
                return [:]
            }
            return try JSONDecoder().decode([String: InstalledRecipe].self, from: data)
        },
        saveInstalled: { recipes in
            try FileManager.default.createDirectory(
                at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(recipes).write(to: installed, options: .atomic)
        })
}

private let readableExtensions: Set<String> = ["ts", "js", "json", "md", "mts", "cts"]
private let largestReadable = 1_000_000

func recipeProjectSnapshot(root: URL) throws -> RecipeProjectSnapshot {
    let base = root.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
    guard
        let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [])
    else { throw CocoaError(.fileReadNoSuchFile) }

    var paths: Set<String> = []
    var sources: [String: String] = [:]
    for case let url as URL in walker {
        let absolute = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        let relative = String(absolute.dropFirst(base.count)).trimmingPrefix("/")
        if ignoredByRecipes(String(relative)) {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile != true {
                walker.skipDescendants()
            }
            continue
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { continue }
        paths.insert(String(relative))
        if readableExtensions.contains(url.pathExtension), (values.fileSize ?? 0) <= largestReadable {
            sources[String(relative)] = try String(contentsOf: url, encoding: .utf8)
        }
    }
    return RecipeProjectSnapshot(paths: paths, sources: sources)
}
