import EscribaCore
import SwiftUI

struct NoteDataView: View {
    let rows: [DataRow]

    init(_ data: DataValue) {
        rows = dataRows(data)
    }

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.label)
                        .foregroundStyle(row.value == .group ? .primary : .secondary)
                        .fontWeight(row.value == .group ? .medium : .regular)
                        .padding(.leading, CGFloat(row.depth) * 14)
                        .gridColumnAlignment(.leading)
                    value(row.value)
                }
            }
        }
    }

    @ViewBuilder private func value(_ value: DataRowValue) -> some View {
        switch value {
        case .text(let text):
            Text(text).textSelection(.enabled)
        case .list(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Text("• \(item)").textSelection(.enabled)
                }
            }
        case .group:
            Color.clear.frame(height: 0)
        }
    }
}

struct NoteDataSection: View {
    let data: DataValue?

    var body: some View {
        if let data, !dataRows(data).isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Datos").font(.headline)
                NoteDataView(data)
            }
        }
    }
}
