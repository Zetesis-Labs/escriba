import Foundation

public struct NotionPageRef: Equatable, Sendable {
    public let id: String
    public let url: URL?

    public init(id: String, url: URL?) {
        self.id = id
        self.url = url
    }
}

func parseDataSources(_ json: JSONValue) -> [NotionDataSource] {
    guard case .array(let results)? = json["results"] else { return [] }

    return results.compactMap { result in
        guard result["object"]?.text == "data_source", let id = result["id"]?.text else { return nil }
        return NotionDataSource(
            id: id,
            databaseTitle: title(of: result),
            title: title(of: result),
            properties: properties(of: result))
    }
}

func parsePage(_ json: JSONValue) -> NotionPageRef? {
    guard json["object"]?.text == "page", let id = json["id"]?.text else { return nil }
    return NotionPageRef(id: id, url: json["url"]?.text.flatMap(URL.init(string:)))
}

func parseFirstPage(_ json: JSONValue) -> NotionPageRef? {
    guard case .array(let results)? = json["results"], let first = results.first,
        let id = first["id"]?.text
    else { return nil }
    return NotionPageRef(id: id, url: first["url"]?.text.flatMap(URL.init(string:)))
}

func parseErrorMessage(_ json: JSONValue) -> String? {
    json["message"]?.text
}

func nextCursor(_ json: JSONValue) -> String? {
    guard json["has_more"] == .bool(true) else { return nil }
    return json["next_cursor"]?.text
}

private func title(of result: JSONValue) -> String {
    if let name = result["name"]?.text { return name }
    guard case .array(let parts)? = result["title"] else { return "Sin título" }
    let text = parts.compactMap { $0["plain_text"]?.text }.joined()
    return text.isEmpty ? "Sin título" : text
}

private func properties(of result: JSONValue) -> [NotionProperty] {
    guard case .object(let fields)? = result["properties"] else { return [] }

    return fields.compactMap { name, value in
        value["type"]?.text.map { NotionProperty(name: name, type: $0) }
    }
}
