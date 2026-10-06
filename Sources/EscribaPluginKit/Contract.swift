import Foundation
import EscribaCore

public let pluginContractVersion = 1

public struct PluginManifest: Codable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let version: String
    public let contract: Int
    public let secrets: [String]
    public let folder: String?
    public let hosts: [String]

    public init(id: String, name: String, version: String, secrets: [String] = [], folder: String? = nil, hosts: [String] = []) {
        self.id = id
        self.name = name
        self.version = version
        self.contract = pluginContractVersion
        self.secrets = secrets
        self.folder = folder
        self.hosts = hosts
    }
}

public struct PluginNote: Codable, Sendable, Equatable {
    public let key: String
    public let url: String
    public let startedAt: Date
    public let segments: [TranscriptSegment]
    public let text: String
    public let digest: Digest?

    public init(_ note: Note) {
        key = note.recording.key
        url = note.recording.url.path(percentEncoded: false)
        startedAt = note.recording.startedAt
        segments = note.transcript.segments
        text = note.transcript.text
        digest = note.digest
    }

    public var note: Note {
        Note(
            recording: Recording(url: URL(fileURLWithPath: url), startedAt: startedAt, key: key),
            transcript: segments.isEmpty ? Transcript(text: text) : Transcript(segments: segments),
            digest: digest)
    }
}

public struct PluginRef: Codable, Sendable, Equatable {
    public let id: String
    public let url: String?

    public init(id: String, url: String?) {
        self.id = id
        self.url = url
    }
}

public struct PluginRequest: Codable, Sendable, Equatable {
    public enum Command: String, Codable, Sendable {
        case describe
        case form
        case action
        case publish
        case unpublish
    }

    public let command: Command
    public var config: PluginJSON
    public var state: PluginJSON
    public var action: String?
    public var note: PluginNote?
    public var known: PluginRef?
    public var ref: String?
    public var timeZone: String

    public init(
        command: Command, config: PluginJSON = .object([:]), state: PluginJSON = .object([:]), action: String? = nil,
        note: PluginNote? = nil, known: PluginRef? = nil, ref: String? = nil,
        timeZone: String = TimeZone.current.identifier
    ) {
        self.command = command
        self.config = config
        self.state = state
        self.action = action
        self.note = note
        self.known = known
        self.ref = ref
        self.timeZone = timeZone
    }
}

public struct PluginResponse: Codable, Sendable, Equatable {
    public var manifest: PluginManifest?
    public var form: PluginForm?
    public var config: PluginJSON?
    public var state: PluginJSON?
    public var ref: PluginRef?
    public var error: String?

    public init(
        manifest: PluginManifest? = nil, form: PluginForm? = nil, config: PluginJSON? = nil,
        state: PluginJSON? = nil, ref: PluginRef? = nil, error: String? = nil
    ) {
        self.manifest = manifest
        self.form = form
        self.config = config
        self.state = state
        self.ref = ref
        self.error = error
    }

    public static func failure(_ error: Error) -> PluginResponse {
        PluginResponse(error: "\(error)")
    }
}

public struct HostRequest: Codable, Sendable, Equatable {
    public enum Op: String, Codable, Sendable {
        case http
        case read
        case list
        case write
        case remove
        case log
    }

    public let op: Op
    public var method: String?
    public var url: String?
    public var headers: [String: String]?
    public var body: Data?
    public var path: String?
    public var contents: String?
    public var message: String?

    public init(
        op: Op, method: String? = nil, url: String? = nil, headers: [String: String]? = nil, body: Data? = nil,
        path: String? = nil, contents: String? = nil, message: String? = nil
    ) {
        self.op = op
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.path = path
        self.contents = contents
        self.message = message
    }
}

public struct HostResponse: Codable, Sendable, Equatable {
    public var status: Int?
    public var headers: [String: String]?
    public var body: Data?
    public var contents: String?
    public var paths: [String]?
    public var error: String?

    public init(
        status: Int? = nil, headers: [String: String]? = nil, body: Data? = nil, contents: String? = nil,
        paths: [String]? = nil, error: String? = nil
    ) {
        self.status = status
        self.headers = headers
        self.body = body
        self.contents = contents
        self.paths = paths
        self.error = error
    }
}

public struct HostError: Error, CustomStringConvertible, Equatable {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

public let secretMarkerPrefix = "{{secret:"

public func secretMarker(_ field: String) -> String {
    "\(secretMarkerPrefix)\(field)}}"
}

public func substitutingSecrets(_ value: String, secrets: [String: String]) -> String {
    var result = value
    for (field, secret) in secrets {
        result = result.replacingOccurrences(of: secretMarker(field), with: secret)
    }
    return result
}

public func withSecretMarkers(_ config: PluginJSON, present secrets: [String]) -> PluginJSON {
    var config = config
    for field in secrets { config[field] = .string(secretMarker(field)) }
    return config
}

public func pluginJSONEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    return encoder
}

public func pluginJSONDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
