import EscribaCore
import SwiftUI

struct TraceCard: View {
    let trace: RecipeTrace
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            TraceDetail(trace: trace)
                .padding(.top, 6)
        } label: {
            Label(processedHeadline, systemImage: trace.outcome.symbol)
                .foregroundStyle(trace.outcome == .ok ? Color.secondary : Color.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private var processedHeadline: String {
        let parts = [
            "Cómo se procesó", trace.name ?? trace.recipe, trace.outcome.label.lowercased(),
            trace.seconds.map { "\($0.formatted(.number.precision(.fractionLength(1)))) s" },
        ]
        return parts.compactMap { $0 }.joined(separator: " · ")
    }
}

struct TraceDetail: View {
    let trace: RecipeTrace

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spacer()
                Button("Copiar") { copyToPasteboard(recipeTraceText(trace)) }
                    .controlSize(.small)
                    .help("Copia la traza entera como texto")
            }
            ForEach(Array(trace.steps.enumerated()), id: \.offset) { _, step in
                StepRow(step: step)
            }
            if !trace.logs.isEmpty {
                Divider()
                ForEach(Array(trace.logs.enumerated()), id: \.offset) { _, line in
                    LogLineRow(line: line)
                }
            }
            if let data = trace.data.flatMap({ try? parseData($0) }), !dataRows(data).isEmpty {
                Divider()
                Text("Datos guardados").font(.caption).foregroundStyle(.secondary)
                NoteDataView(data)
                    .font(.caption)
            }
            if let error = trace.error {
                Divider()
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }
        }
    }
}

extension RecipeRunOutcome {
    var symbol: String {
        switch self {
        case .ok: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .waiting: "clock"
        }
    }

    var label: String {
        switch self {
        case .ok: "Bien"
        case .failed: "Falló"
        case .waiting: "Esperando"
        }
    }
}

private struct StepRow: View {
    let step: RecipeStep

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: step.error == nil ? "checkmark.circle" : "xmark.circle")
                    .foregroundStyle(step.error == nil ? Color.secondary : Color.orange)
                Text(step.title)
                Spacer()
                Text("\(step.seconds.formatted(.number.precision(.fractionLength(1)))) s")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let error = step.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

struct LogLineRow: View {
    let line: RecipeLogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("+\(line.seconds.formatted(.number.precision(.fractionLength(1)))) s")
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Text(prefix + line.text)
                .foregroundStyle(color)
                .textSelection(.enabled)
        }
        .font(.caption.monospaced())
    }

    private var prefix: String {
        let level = switch line.level {
        case .warn: "aviso "
        case .error: "error "
        case .debug: "debug "
        case .info: ""
        }
        return level + (line.origin.map { "\($0) › " } ?? "")
    }

    private var color: Color {
        switch line.level {
        case .error: .red
        case .warn: .orange
        case .info: .primary
        case .debug: .secondary
        }
    }
}
