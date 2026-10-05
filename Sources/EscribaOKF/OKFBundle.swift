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
}

public struct BundleState: Equatable, Sendable {
    public var notes: [BundleEntry]
    public var transcripts: [BundleEntry]
    public var log: String?

    public init(notes: [BundleEntry] = [], transcripts: [BundleEntry] = [], log: String? = nil) {
        self.notes = notes
        self.transcripts = transcripts
        self.log = log
    }
}

public enum FileChange: Equatable, Sendable {
    case write(path: String, contents: String)
    case remove(path: String)
}

public struct OKFPublication: Equatable, Sendable {
    public let notePath: String
    public let changes: [FileChange]
}

public func bundleState(from files: [String: String]) -> BundleState {
    func concepts(in folder: String) -> [BundleEntry] {
        files
            .filter { isConcept($0.key, in: folder) }
            .map { bundleEntry(path: $0.key, contents: $0.value) }
            .sorted { $0.path < $1.path }
    }
    return BundleState(
        notes: concepts(in: okfNotesFolder),
        transcripts: concepts(in: okfTranscriptsFolder),
        log: files["log.md"])
}

func isConcept(_ path: String, in folder: String) -> Bool {
    let parts = path.split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, parts[0] == folder, parts[1].hasSuffix(".md") else { return false }
    return parts[1] != "index.md" && parts[1] != "log.md"
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
    _ note: Note, as export: OKFExport, in bundle: BundleState, known: String?,
    producer: String, now: Date, timeZone: TimeZone
) -> OKFPublication {
    let facts = noteFacts(note, timeZone: timeZone)
    let previous = (known ?? bundle.notes.first { $0.key == facts.key }?.path)
        .flatMap { path in bundle.notes.contains { $0.path == path } ? path : nil }
    let name = availableName(
        okfFileName(title: facts.title, startedAt: facts.startedAt, timeZone: timeZone),
        for: facts.key, previous: previous, in: bundle)
    let notePath = "\(okfNotesFolder)/\(name)"
    let transcriptPath = "\(okfTranscriptsFolder)/\(name)"
    let transcriptStyle = export.writesTranscript ? export.template.transcriptStyle : nil

    var changes: [FileChange] = [
        .write(
            path: notePath,
            contents: noteDocument(
                facts, transcript: note.transcript, template: export.template,
                transcriptLink: transcriptStyle.map { _ in "/\(transcriptPath)" },
                producer: producer, now: now, timeZone: timeZone)),
    ]
    if let transcriptStyle {
        changes.append(.write(
            path: transcriptPath,
            contents: transcriptDocument(
                facts, transcript: note.transcript, style: transcriptStyle, notePath: notePath,
                producer: producer, now: now, timeZone: timeZone)))
    }

    var removed: Set<String> = []
    if let previous, previous != notePath { removed.insert(previous) }
    let staleTranscripts = [previous.map(sibling), transcriptStyle == nil ? transcriptPath : nil]
        .compactMap { $0 }
        .filter { path in path != transcriptPath || transcriptStyle == nil }
        .filter { path in bundle.transcripts.contains { $0.path == path } }
    removed.formUnion(staleTranscripts)
    changes += removed.sorted().map { .remove(path: $0) }

    let entry = BundleEntry(path: notePath, title: facts.title, description: facts.description, key: facts.key)
    let notes = bundle.notes.filter { !removed.contains($0.path) && $0.path != notePath } + [entry]
    let transcripts = bundle.transcripts.filter { !removed.contains($0.path) && $0.path != transcriptPath }
        + (transcriptStyle == nil ? [] : [
            BundleEntry(
                path: transcriptPath, title: "Transcripción: \(facts.title)",
                description: "Transcripción completa de «\(facts.title)».", key: facts.key),
        ])
    changes += indexChanges(notes: notes, transcripts: transcripts)

    let verb = previous == nil ? "Alta" : "Actualización"
    changes.append(.write(
        path: "log.md",
        contents: logging(
            "* **\(verb)**: [\(linkText(facts.title))](/\(notePath))", marker: "(/\(notePath))",
            on: isoDay(now, timeZone: timeZone), in: bundle.log)))

    return OKFPublication(notePath: notePath, changes: changes)
}

public func okfRemoval(of notePath: String, in bundle: BundleState, now: Date, timeZone: TimeZone) -> [FileChange] {
    let transcriptPath = sibling(of: notePath)
    var changes: [FileChange] = [.remove(path: notePath)]
    if bundle.transcripts.contains(where: { $0.path == transcriptPath }) {
        changes.append(.remove(path: transcriptPath))
    }
    let entry = bundle.notes.first { $0.path == notePath }
    let title = entry?.title ?? String((entry?.fileName ?? notePath).dropLast(3))
    changes += indexChanges(
        notes: bundle.notes.filter { $0.path != notePath },
        transcripts: bundle.transcripts.filter { $0.path != transcriptPath })
    changes.append(.write(
        path: "log.md",
        contents: logging(
            "* **Baja**: \(title) (\(notePath))", marker: "(\(notePath))",
            on: isoDay(now, timeZone: timeZone), in: bundle.log)))
    return changes
}

private func sibling(of notePath: String) -> String {
    "\(okfTranscriptsFolder)/\(notePath.split(separator: "/").last ?? Substring(notePath))"
}

private func availableName(
    _ base: String, for key: String, previous: String?, in bundle: BundleState
) -> String {
    let stem = base.dropLast(3)
    for attempt in 1... {
        let candidate = attempt == 1 ? base : "\(stem)-\(attempt).md"
        let path = "\(okfNotesFolder)/\(candidate)"
        if path == previous { return candidate }
        guard let occupant = bundle.notes.first(where: { $0.path == path }) else { return candidate }
        if occupant.key == key { return candidate }
    }
    return base
}

private func indexChanges(notes: [BundleEntry], transcripts: [BundleEntry]) -> [FileChange] {
    var sections: [String] = []
    var changes: [FileChange] = []
    if notes.isEmpty {
        changes.append(.remove(path: "\(okfNotesFolder)/index.md"))
    } else {
        changes.append(.write(path: "\(okfNotesFolder)/index.md", contents: directoryIndex(notes, others: "Otras notas")))
        sections.append("* [Notas](\(okfNotesFolder)/) - Una nota por grabación, con su resumen y sus datos.")
    }
    if transcripts.isEmpty {
        changes.append(.remove(path: "\(okfTranscriptsFolder)/index.md"))
    } else {
        changes.append(.write(
            path: "\(okfTranscriptsFolder)/index.md",
            contents: directoryIndex(transcripts, others: "Otras transcripciones")))
        sections.append(
            "* [Transcripciones](\(okfTranscriptsFolder)/) - La transcripción completa de cada grabación.")
    }
    if sections.isEmpty {
        changes.append(.remove(path: "index.md"))
    } else {
        changes.append(.write(path: "index.md", contents: "# Notas de voz\n\n" + sections.joined(separator: "\n") + "\n"))
    }
    return changes
}

func directoryIndex(_ entries: [BundleEntry], others: String) -> String {
    let grouped = Dictionary(grouping: entries) { monthKey(of: $0.fileName) }
    let dated = grouped.keys.compactMap { $0 }.sorted(by: >).map { key in
        (heading: monthHeading(year: key / 100, month: key % 100),
         entries: grouped[key, default: []].sorted { $0.fileName > $1.fileName })
    }
    let undated = (grouped[nil] ?? []).sorted { $0.fileName < $1.fileName }
    let sections = dated + (undated.isEmpty ? [] : [(heading: others, entries: undated)])
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
