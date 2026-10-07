import EscribaCore
import SwiftUI

struct TraceCard: View {
    let trace: RecipeTrace
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(trace.steps.enumerated()), id: \.offset) { _, step in
                    StepRow(step: step)
                }
                if !trace.logs.isEmpty {
                    Divider()
                    ForEach(Array(trace.logs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                if let error = trace.error {
                    Divider()
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            .padding(.top, 6)
        } label: {
            Label(trace.headline, systemImage: trace.error == nil ? "list.bullet.rectangle" : "exclamationmark.triangle")
                .foregroundStyle(trace.error == nil ? Color.secondary : Color.orange)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
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
