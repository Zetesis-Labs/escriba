import AppKit
import EscribaEngine
import SwiftUI

struct SelectableLogView: NSViewRepresentable {
    let lines: [LogEntry]

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isSelectable = true
            text.drawsBackground = false
            text.textContainerInset = NSSize(width: 8, height: 8)
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView, let storage = text.textStorage else { return }
        let rendered = logAttributedText(lines)
        guard storage.string != rendered.string else { return }
        let atBottom = scroll.contentView.bounds.maxY >= text.bounds.maxY - 40
        storage.setAttributedString(rendered)
        if atBottom { text.scrollToEndOfDocument(nil) }
    }
}

func logPlainText(_ lines: [LogEntry]) -> String {
    lines.map { line in [line.time, line.message].compactMap { $0 }.joined(separator: " ") }.joined(separator: "\n")
}

private func logAttributedText(_ lines: [LogEntry]) -> NSAttributedString {
    let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    let result = NSMutableAttributedString()
    for (index, line) in lines.enumerated() {
        if let time = line.time {
            result.append(NSAttributedString(
                string: time + " ", attributes: [.font: font, .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        let color: NSColor = switch line.level {
        case .error: .systemRed
        case .debug: .secondaryLabelColor
        case .info, .other: .labelColor
        }
        result.append(NSAttributedString(
            string: line.message + (index < lines.count - 1 ? "\n" : ""),
            attributes: [.font: font, .foregroundColor: color]))
    }
    return result
}

func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
