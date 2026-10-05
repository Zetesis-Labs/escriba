import Foundation
import EscribaCore

public struct BundleEntry: Equatable, Sendable {
    public let path: String
    public let title: String?
    public let description: String?
    public let key: String?

    public init(path: String, title: String?, description: String?, key: String?) {
        self.path = path
        self.title = title
        self.description = description
        self.key = key
    }

    var fileName: String { String(path.split(separator: "/").last ?? Substring(path)) }

    var directory: String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}

public struct BundleState: Equatable, Sendable {
    public var entries: [BundleEntry]
    public var log: String?

    public init(entries: [BundleEntry] = [], log: String? = nil) {
        self.entries = entries
        self.log = log
    }
}

public enum FileChange: Equatable, Sendable {
    case write(path: String, contents: String)
    case remove(path: String)
}

public struct OKFPublication: Equatable, Sendable {
    public let paths: [String]
    public let changes: [FileChange]

    public var notePath: String { paths.first ?? "" }
}

func isReserved(_ path: String) -> Bool {
    let name = path.split(separator: "/").last.map(String.init) ?? path
    return name == "index.md" || name == "log.md"
}

func isConcept(_ path: String) -> Bool {
    path.lowercased().hasSuffix(".md") && !isReserved(path)
}

public func bundleState(from files: [String: String]) -> BundleState {
    BundleState(
        entries: files
            .filter { isConcept($0.key) }
            .map { bundleEntry(path: $0.key, contents: $0.value) }
            .sorted { $0.path < $1.path },
        log: files["log.md"])
}

public func bundleEntry(path: String, contents: String) -> BundleEntry {
    var fields: [String: String] = [:]
    let lines = contents.components(separatedBy: "\n")
    if lines.first == "---" {
        for line in lines.dropFirst() {
            if line == "---" { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            fields[name] = yamlScalar(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
    }
    return BundleEntry(
        path: path, title: fields["title"], description: fields["description"], key: fields["escriba_key"])
}

private func yamlScalar(_ raw: String) -> String? {
    guard !raw.isEmpty else { return nil }
    if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") {
        var result = ""
        var escaping = false
        for character in raw.dropFirst().dropLast() {
            if escaping {
                result.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        return result
    }
    if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
        return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
    }
    return raw
}

public func okfPublication(
    _ note: Note, as export: OKFExport, in bundle: BundleState, producer: String, now: Date, timeZone: TimeZone
) -> OKFPublication {
    let facts = noteFacts(note, timeZone: timeZone)
    let previous = bundle.entries.filter { $0.key == facts.key }.map(\.path)

    var taken: Set<String> = []
    let paths = export.documents.map { document in
        let path = availablePath(renderedPath(document.path, of: facts), for: facts.key, taken: taken, in: bundle)
        taken.insert(path)
        return path
    }
    let links = Dictionary(
        zip(export.documents, paths).map { ($0.id, RenderedLink(path: $1, title: documentTitle($0, of: facts))) },
        uniquingKeysWith: { first, _ in first })

    var changes: [FileChange] = zip(export.documents, paths).map { document, path in
        .write(path: path, contents: documentContents(document, of: facts, links: links, producer: producer, now: now))
    }
    let removed = Set(previous).subtracting(paths)
    changes += removed.sorted().map { .remove(path: $0) }

    let written = zip(export.documents, paths).map { document, path in
        BundleEntry(
            path: path, title: documentTitle(document, of: facts),
            description: documentDescription(document, of: facts), key: facts.key)
    }
    let after = bundle.entries.filter { !removed.contains($0.path) && !paths.contains($0.path) } + written
    changes += indexChanges(before: bundle.entries, after: after, documents: export.documents)

    if let main = paths.first {
        let verb = previous.isEmpty ? "Alta" : "Actualización"
        changes.append(.write(
            path: "log.md",
            contents: logging(
                "* **\(verb)**: [\(linkText(facts.title))](/\(main))", marker: "(/\(main))",
                on: isoDay(now, timeZone: timeZone), in: bundle.log)))
    }
    return OKFPublication(paths: paths, changes: changes)
}

public func okfRemoval(
    of notePath: String, in bundle: BundleState, documents: [OKFDocument] = [], now: Date, timeZone: TimeZone
) -> [FileChange] {
    let entry = bundle.entries.first { $0.path == notePath }
    let targets = Set(entry?.key.map { key in bundle.entries.filter { $0.key == key }.map(\.path) } ?? [])
        .union([notePath])
    let title = entry?.title ?? String((entry?.fileName ?? notePath).dropLast(3))
    let after = bundle.entries.filter { !targets.contains($0.path) }
    return targets.sorted().map { .remove(path: $0) }
        + indexChanges(before: bundle.entries, after: after, documents: documents)
        + [.write(
            path: "log.md",
            contents: logging(
                "* **Baja**: \(title) (\(notePath))", marker: "(\(notePath))",
                on: isoDay(now, timeZone: timeZone), in: bundle.log))]
}

private func availablePath(_ base: String, for key: String, taken: Set<String>, in bundle: BundleState) -> String {
    let stem = base.dropLast(3)
    for attempt in 1... {
        let candidate = attempt == 1 ? base : "\(stem)-\(attempt).md"
        guard !taken.contains(candidate) else { continue }
        guard let occupant = bundle.entries.first(where: { $0.path == candidate }) else { return candidate }
        if occupant.key == key { return candidate }
    }
    return base
}

private func indexChanges(before: [BundleEntry], after: [BundleEntry], documents: [OKFDocument]) -> [FileChange] {
    let ownedAfter = Set(after.filter { $0.key != nil }.map(\.directory))
    let ownedBefore = Set(before.filter { $0.key != nil }.map(\.directory))
    let folders = ownedAfter.filter { !$0.isEmpty }.sorted()

    var changes: [FileChange] = folders.map { folder in
        .write(path: "\(folder)/index.md", contents: directoryIndex(after.filter { $0.directory == folder }))
    }
    changes += ownedBefore.subtracting(ownedAfter).filter { !$0.isEmpty }.sorted()
        .map { .remove(path: "\($0)/index.md") }

    guard !ownedAfter.isEmpty else { return changes + [.remove(path: "index.md")] }
    let lines = folders.map { folder in
        let names = documents.filter { staticDirectory(of: $0.path) == folder }.map(\.name)
        let link = "* [\(folder)](\(folder)/)"
        return names.isEmpty ? link : "\(link) - \(names.joined(separator: ", "))"
    }
    var root = "# Notas de voz\n"
    if !lines.isEmpty { root += "\n" + lines.joined(separator: "\n") + "\n" }
    if ownedAfter.contains("") {
        root += "\n" + directoryIndex(after.filter { $0.directory.isEmpty })
    }
    return changes + [.write(path: "index.md", contents: root)]
}

private func staticDirectory(of template: String) -> String? {
    let trimmed = template.trimmingCharacters(in: .whitespaces)
    guard let slash = trimmed.lastIndex(of: "/") else { return "" }
    let folder = trimmed[..<slash]
    guard !folder.contains("{{") else { return nil }
    return folder.split(separator: "/")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        .joined(separator: "/")
}

func directoryIndex(_ entries: [BundleEntry]) -> String {
    let grouped = Dictionary(grouping: entries) { monthKey(of: $0.fileName) }
    let dated = grouped.keys.compactMap { $0 }.sorted(by: >).map { key in
        (heading: monthHeading(year: key / 100, month: key % 100),
         entries: grouped[key, default: []].sorted { $0.fileName > $1.fileName })
    }
    let undated = (grouped[nil] ?? []).sorted { $0.fileName < $1.fileName }
    let sections = dated + (undated.isEmpty ? [] : [(heading: "Otras", entries: undated)])
    return sections
        .map { section in "# \(section.heading)\n\n" + section.entries.map(indexLine).joined(separator: "\n") }
        .joined(separator: "\n\n") + "\n"
}

private func indexLine(_ entry: BundleEntry) -> String {
    let title = entry.title ?? String(entry.fileName.dropLast(3))
    let link = "* [\(linkText(title))](\(entry.fileName))"
    guard let description = entry.description, !description.isEmpty else { return link }
    return "\(link) - \(description)"
}

private func monthKey(of fileName: String) -> Int? {
    guard let match = fileName.prefixMatch(of: /(\d{4})-(\d{2})-/),
        let year = Int(match.1), let month = Int(match.2), (1...12).contains(month)
    else { return nil }
    return year * 100 + month
}

func logging(_ line: String, marker: String, on day: String, in existing: String?) -> String {
    let lines = (existing ?? "").components(separatedBy: "\n")
    let firstDated = lines.firstIndex { $0.hasPrefix("## ") }
    var header = Array(lines[..<(firstDated ?? lines.endIndex)])
    while header.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { header.removeLast() }
    if header.isEmpty { header = ["# Registro"] }

    guard let firstDated else {
        return finished(header + ["", "## \(day)", "", line])
    }
    let rest = Array(lines[firstDated...])
    guard rest[0].trimmingCharacters(in: .whitespaces) == "## \(day)" else {
        return finished(header + ["", "## \(day)", "", line, ""] + rest)
    }
    let sectionEnd = rest.dropFirst().firstIndex { $0.hasPrefix("## ") } ?? rest.endIndex
    if rest[1..<sectionEnd].contains(where: { $0.contains(marker) }) { return existing ?? "" }
    let entries = rest[1..<sectionEnd].drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
    return finished(header + ["", rest[0], "", line] + entries + rest[sectionEnd...])
}

private func finished(_ lines: [String]) -> String {
    var text = lines.joined(separator: "\n")
    while text.hasSuffix("\n") { text.removeLast() }
    return text + "\n"
}
