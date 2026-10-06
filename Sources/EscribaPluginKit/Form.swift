import Foundation

public struct FormLink: Codable, Sendable, Equatable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public struct FormTab: Codable, Sendable, Equatable {
    public let id: String
    public let label: String
    public let items: [FormItem]

    public init(id: String, label: String, items: [FormItem]) {
        self.id = id
        self.label = label
        self.items = items
    }
}

public struct FormOption: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct FormItem: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case section
        case row
        case text
        case secret
        case folder
        case choice
        case template
        case button
        case label
        case note
        case preview
        case tabs
    }

    public enum TemplateContext: String, Codable, Sendable {
        case body
        case property
        case path
    }

    public enum Style: String, Codable, Sendable {
        case plain
        case caption
        case warning
        case monospaced
    }

    public let kind: Kind
    public var path: String?
    public var label: String?
    public var text: String?
    public var help: String?
    public var header: String?
    public var footer: String?
    public var placeholder: String?
    public var options: [FormOption]?
    public var emptyLabel: String?
    public var context: TemplateContext?
    public var links: [FormLink]?
    public var current: String?
    public var multiline: Bool?
    public var monospaced: Bool?
    public var width: Double?
    public var readOnly: Bool?
    public var enabled: Bool?
    public var action: String?
    public var symbol: String?
    public var destructive: Bool?
    public var style: Style?
    public var showInFinder: Bool?
    public var items: [FormItem]?
    public var tabs: [FormTab]?
    public var addAction: String?
    public var removeAction: String?

    public init(kind: Kind) {
        self.kind = kind
    }

    public static func section(_ header: String? = nil, footer: String? = nil, _ items: [FormItem]) -> FormItem {
        var item = FormItem(kind: .section)
        item.header = header
        item.footer = footer
        item.items = items
        return item
    }

    public static func row(_ items: [FormItem]) -> FormItem {
        var item = FormItem(kind: .row)
        item.items = items
        return item
    }

    public static func text(
        _ path: String, label: String? = nil, placeholder: String? = nil, monospaced: Bool = false,
        width: Double? = nil, readOnly: Bool = false
    ) -> FormItem {
        var item = FormItem(kind: .text)
        item.path = path
        item.label = label
        item.placeholder = placeholder
        item.monospaced = monospaced
        item.width = width
        item.readOnly = readOnly
        return item
    }

    public static func secret(_ path: String, label: String, help: String? = nil) -> FormItem {
        var item = FormItem(kind: .secret)
        item.path = path
        item.label = label
        item.help = help
        return item
    }

    public static func folder(_ path: String, showInFinder: Bool = true) -> FormItem {
        var item = FormItem(kind: .folder)
        item.path = path
        item.showInFinder = showInFinder
        return item
    }

    public static func choice(_ path: String, label: String, options: [FormOption], emptyLabel: String = "Sin elegir") -> FormItem {
        var item = FormItem(kind: .choice)
        item.path = path
        item.label = label
        item.options = options
        item.emptyLabel = emptyLabel
        return item
    }

    public static func template(
        _ path: String, label: String? = nil, context: TemplateContext, placeholder: String? = nil,
        multiline: Bool = false, links: [FormLink] = [], current: String? = nil
    ) -> FormItem {
        var item = FormItem(kind: .template)
        item.path = path
        item.label = label
        item.context = context
        item.placeholder = placeholder
        item.multiline = multiline
        item.links = links
        item.current = current
        return item
    }

    public static func button(
        _ label: String, action: String, symbol: String? = nil, destructive: Bool = false, enabled: Bool = true
    ) -> FormItem {
        var item = FormItem(kind: .button)
        item.label = label
        item.action = action
        item.symbol = symbol
        item.destructive = destructive
        item.enabled = enabled
        return item
    }

    public static func label(_ text: String, help: String? = nil, width: Double? = nil, monospaced: Bool = false) -> FormItem {
        var item = FormItem(kind: .label)
        item.text = text
        item.help = help
        item.width = width
        item.monospaced = monospaced
        return item
    }

    public static func note(_ text: String, style: Style = .caption) -> FormItem {
        var item = FormItem(kind: .note)
        item.text = text
        item.style = style
        return item
    }

    public static func preview(_ text: String, label: String? = nil) -> FormItem {
        var item = FormItem(kind: .preview)
        item.text = text
        item.label = label
        return item
    }

    /// Una vista previa que el plugin calcula aparte, con el comando `preview`, bajo esta clave.
    public static func preview(key: String) -> FormItem {
        var item = FormItem(kind: .preview)
        item.path = key
        return item
    }

    public static func tabs(_ tabs: [FormTab], addAction: String, removeAction: String) -> FormItem {
        var item = FormItem(kind: .tabs)
        item.tabs = tabs
        item.addAction = addAction
        item.removeAction = removeAction
        return item
    }
}

public struct PluginForm: Codable, Sendable, Equatable {
    public var items: [FormItem]
    public var problem: String?

    public init(items: [FormItem], problem: String? = nil) {
        self.items = items
        self.problem = problem
    }
}
