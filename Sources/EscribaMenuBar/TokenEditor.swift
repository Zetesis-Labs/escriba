import AppKit
import EscribaCore
import SwiftUI

struct TokenEditor: View {
    @Binding var source: String
    let context: TemplateContext
    var links: [LinkTarget] = []
    var current: String?
    var placeholder = ""
    var multiline = false
    @State private var controller = TokenFieldController()

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            TokenTextField(
                source: $source, context: context, links: links, current: current, placeholder: placeholder,
                multiline: multiline, controller: controller
            )
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            Menu {
                ForEach(tokenSuggestions(matching: "", in: context, links: links, excluding: current)) { suggestion in
                    Button(suggestion.label) { controller.insert(suggestion.token) }
                }
            } label: {
                Image(systemName: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.top, 3)
            .help("Insertar un dato aquí (o escribe / en el texto)")
        }
    }
}

final class TokenFieldController {
    weak var textView: TokenTextView?

    func insert(_ token: TemplateToken) {
        textView?.insertToken(token)
    }
}

struct TokenTextField: NSViewRepresentable {
    @Binding var source: String
    let context: TemplateContext
    let links: [LinkTarget]
    let current: String?
    let placeholder: String
    let multiline: Bool
    let controller: TokenFieldController

    func makeNSView(context: Context) -> TokenTextView {
        let view = TokenTextView.make(multiline: multiline)
        configure(view)
        view.load(source)
        return view
    }

    func updateNSView(_ view: TokenTextView, context: Context) {
        let names = Dictionary(links.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let renamed = view.names != names
        configure(view)
        if renamed || view.serialized() != source { view.load(source) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TokenTextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 240
        return CGSize(width: width, height: nsView.fittingHeight(width: width))
    }

    private func configure(_ view: TokenTextView) {
        let binding = $source
        let (context, links, current) = (self.context, self.links, self.current)
        view.tokenContext = context
        view.names = Dictionary(links.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        view.placeholder = placeholder
        view.suggest = { tokenSuggestions(matching: $0, in: context, links: links, excluding: current) }
        view.onChange = { binding.wrappedValue = $0 }
        controller.textView = view
    }
}

final class TokenTextView: NSTextView {
    var tokenContext: TemplateContext = .body
    var multiline = true
    var names: [String: String] = [:]
    var placeholder = "" {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    var suggest: (String) -> [TokenSuggestion] = { _ in [] }
    var onChange: (String) -> Void = { _ in }

    private let suggestions = SuggestionMenu()
    private var popover: NSPopover?
    private var slashStart: Int?
    private var lastQuery: String?
    private var reloading = false

    static func make(multiline: Bool) -> TokenTextView {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        container.lineFragmentPadding = 4
        layout.addTextContainer(container)

        let view = TokenTextView(frame: .zero, textContainer: container)
        view.multiline = multiline
        view.isRichText = true
        view.importsGraphics = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainerInset = NSSize(width: 4, height: multiline ? 8 : 4)
        view.typingAttributes = view.baseAttributes
        view.suggestions.onPick = { [weak view] in view?.pick($0) }
        return view
    }

    private var baseFont: NSFont { .systemFont(ofSize: NSFont.systemFontSize) }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: NSColor.labelColor]
    }

    func load(_ source: String) {
        reloading = true
        defer { reloading = false }
        textStorage?.setAttributedString(attributed(source))
        restyle()
        closeSuggestions()
        invalidateIntrinsicContentSize()
    }

    func serialized(in range: NSRange? = nil) -> String {
        guard let storage = textStorage else { return "" }
        let range = range ?? NSRange(location: 0, length: storage.length)
        var pieces: [TemplatePiece] = []
        storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            if let attachment = value as? TokenAttachment {
                pieces += Array(repeating: .token(attachment.token), count: run.length)
            } else {
                let text = (storage.string as NSString).substring(with: run).replacingOccurrences(of: "\u{FFFC}", with: "")
                if !text.isEmpty { pieces.append(.text(text)) }
            }
        }
        return templateSource(pieces)
    }

    func insertToken(_ token: TemplateToken) {
        window?.makeFirstResponder(self)
        replace(selectedRange(), with: tokenString(token))
    }

    func fittingHeight(width: CGFloat) -> CGFloat {
        guard let layoutManager, let textContainer else { return 24 }
        textContainer.containerSize = NSSize(
            width: max(width - textContainerInset.width * 2, 10), height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let used = ceil(layoutManager.usedRect(for: textContainer).height) + textContainerInset.height * 2
        return max(used, multiline ? 160 : ceil(baseFont.boundingRectForFont.height) + textContainerInset.height * 2)
    }

    override func didChangeText() {
        super.didChangeText()
        guard !reloading else { return }
        restyle()
        onChange(serialized())
        invalidateIntrinsicContentSize()
        refreshSuggestions()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !reloading, !stillSelecting { refreshSuggestions() }
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { closeSuggestions() }
        return resigned
    }

    override func doCommand(by selector: Selector) {
        if popover?.isShown == true {
            switch selector {
            case #selector(moveDown(_:)):
                suggestions.next()
                return
            case #selector(moveUp(_:)):
                suggestions.previous()
                return
            case #selector(insertNewline(_:)), #selector(insertTab(_:)):
                if let current = suggestions.current { pick(current) }
                return
            case #selector(cancelOperation(_:)):
                closeSuggestions()
                return
            default:
                break
            }
        }
        if !multiline {
            switch selector {
            case #selector(insertNewline(_:)), #selector(insertLineBreak(_:)), #selector(insertParagraphSeparator(_:)):
                return
            case #selector(insertTab(_:)):
                window?.selectNextKeyView(self)
                return
            case #selector(insertBacktab(_:)):
                window?.selectPreviousKeyView(self)
                return
            default:
                break
            }
        }
        super.doCommand(by: selector)
    }

    override func copy(_ sender: Any?) {
        let selection = selectedRange()
        guard selection.length > 0 else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(serialized(in: selection), forType: .string)
    }

    override func cut(_ sender: Any?) {
        copy(sender)
        replace(selectedRange(), with: NSAttributedString())
    }

    override func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        replace(selectedRange(), with: attributed(text))
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let origin = NSPoint(
            x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 0), y: textContainerOrigin.y)
        (placeholder as NSString).draw(
            at: origin, withAttributes: [.font: baseFont, .foregroundColor: NSColor.placeholderTextColor])
    }

    private func attributed(_ source: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for piece in templatePieces(source) {
            switch piece {
            case .text(let text):
                let visible = multiline ? text : text.replacingOccurrences(of: "\n", with: " ")
                result.append(NSAttributedString(string: visible, attributes: baseAttributes))
            case .token(let token):
                result.append(tokenString(token))
            }
        }
        return result
    }

    private func tokenString(_ token: TemplateToken) -> NSAttributedString {
        let attachment = TokenAttachment(token: token, label: token.label(names: names), font: baseFont)
        let string = NSMutableAttributedString(attachment: attachment)
        string.addAttributes(baseAttributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    private func replace(_ range: NSRange, with replacement: NSAttributedString) {
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        textStorage?.replaceCharacters(in: range, with: replacement)
        setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
        typingAttributes = baseAttributes
        didChangeText()
    }

    private func restyle() {
        guard multiline, let storage = textStorage else { return }
        let text = storage.string as NSString
        storage.beginEditing()
        var location = 0
        while location < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
            storage.addAttribute(.font, value: font(forLine: text.substring(with: paragraph)), range: paragraph)
            location = NSMaxRange(paragraph)
        }
        storage.endEditing()
    }

    private func font(forLine line: String) -> NSFont {
        guard let match = line.prefixMatch(of: /(#{1,6})\s/) else { return baseFont }
        switch match.1.count {
        case 1: return .systemFont(ofSize: 20, weight: .bold)
        case 2: return .systemFont(ofSize: 16, weight: .semibold)
        default: return .systemFont(ofSize: 14, weight: .semibold)
        }
    }

    private func pick(_ suggestion: TokenSuggestion) {
        let caret = selectedRange().location
        let start = slashStart ?? caret
        closeSuggestions()
        replace(NSRange(location: start, length: max(caret - start, 0)), with: tokenString(suggestion.token))
        window?.makeFirstResponder(self)
    }

    private func refreshSuggestions() {
        guard let query = slashQuery() else { return closeSuggestions() }
        let items = suggest(query.text)
        guard !items.isEmpty else { return closeSuggestions() }
        if query.text != lastQuery { suggestions.selected = 0 }
        lastQuery = query.text
        slashStart = query.start
        suggestions.items = items
        showSuggestions(at: query.start)
    }

    private func slashQuery() -> (start: Int, text: String)? {
        let selection = selectedRange()
        guard selection.length == 0, let storage = textStorage else { return nil }
        let text = storage.string as NSString
        var index = selection.location - 1
        var query = ""
        while index >= 0, selection.location - index <= 32 {
            let character = character(at: index, in: text)
            if character == "/" {
                return triggers(after: index > 0 ? self.character(at: index - 1, in: text) : nil)
                    ? (index, query) : nil
            }
            if character.isWhitespace || character == "\u{FFFC}" { return nil }
            query = String(character) + query
            index -= 1
        }
        return nil
    }

    private func character(at index: Int, in text: NSString) -> Character {
        UnicodeScalar(text.character(at: index)).map(Character.init) ?? " "
    }

    private func triggers(after previous: Character?) -> Bool {
        guard let previous else { return true }
        if previous.isWhitespace || previous == "\u{FFFC}" { return true }
        switch tokenContext {
        case .path: return "/-_".contains(previous)
        case .body, .property: return "([".contains(previous)
        }
    }

    private func showSuggestions(at location: Int) {
        guard let layoutManager, let textContainer else { return }
        let glyphs = layoutManager.glyphRange(
            forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        var rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: textContainer)
        rect.origin.x += textContainerOrigin.x
        rect.origin.y += textContainerOrigin.y
        if let popover, popover.isShown {
            popover.positioningRect = rect
            return
        }
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        let host = NSHostingController(rootView: SuggestionList(menu: suggestions))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
        self.popover = popover
        window?.makeFirstResponder(self)
    }

    private func closeSuggestions() {
        popover?.close()
        popover = nil
        slashStart = nil
        lastQuery = nil
    }
}

nonisolated final class TokenAttachment: NSTextAttachment {
    let token: TemplateToken

    init(token: TemplateToken, label: String, font: NSFont) {
        self.token = token
        super.init(data: nil, ofType: nil)
        let labelFont = NSFont.systemFont(ofSize: font.pointSize - 1, weight: .medium)
        let text = (label as NSString).size(withAttributes: [.font: labelFont])
        let size = NSSize(width: ceil(text.width) + 14, height: ceil(text.height) + 4)
        image = NSImage(size: size, flipped: false) { rect in
            let pill = rect.insetBy(dx: 1, dy: 0.5)
            let path = NSBezierPath(roundedRect: pill, xRadius: 5, yRadius: 5)
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.45).setStroke()
            path.lineWidth = 1
            path.stroke()
            (label as NSString).draw(
                at: NSPoint(x: pill.midX - text.width / 2, y: pill.midY - text.height / 2),
                withAttributes: [.font: labelFont, .foregroundColor: NSColor.labelColor])
            return true
        }
        bounds = NSRect(x: 0, y: labelFont.descender - 2, width: size.width, height: size.height)
    }

    required init?(coder: NSCoder) {
        return nil
    }
}

@Observable
final class SuggestionMenu {
    var items: [TokenSuggestion] = []
    var selected = 0
    var onPick: (TokenSuggestion) -> Void = { _ in }

    var current: TokenSuggestion? { items.indices.contains(selected) ? items[selected] : nil }

    func next() { selected = min(selected + 1, max(items.count - 1, 0)) }

    func previous() { selected = max(selected - 1, 0) }
}

private struct SuggestionList: View {
    let menu: SuggestionMenu

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(menu.items.enumerated()), id: \.element.id) { index, item in
                        Button {
                            menu.onPick(item)
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.label)
                                Text(item.help).font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                index == menu.selected ? Color.accentColor.opacity(0.25) : .clear,
                                in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(6)
            }
            .onChange(of: menu.selected) { _, selected in proxy.scrollTo(selected) }
        }
        .frame(width: 300, height: min(CGFloat(menu.items.count) * 42 + 12, 320))
    }
}
