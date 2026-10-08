import EscribaCore
import SwiftUI

struct RecipeFormSections: View {
    let form: RecipeForm
    @Binding var values: DataValue

    var body: some View {
        ForEach(recipeFormSections(form), id: \.path) { section in
            Section(section.title ?? "Parámetros") {
                ForEach(section.fields, id: \.name) { field in
                    RecipeFormRow(field: field, path: section.path + [field.name], values: $values)
                }
            }
        }
    }
}

private struct RecipeFormRow: View {
    let field: RecipeFormField
    let path: [String]
    @Binding var values: DataValue

    private var value: DataValue? { values.value(at: path) }
    private var empty: DataValue? { field.nullable ? .null : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            if let help = field.help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let issue = recipeFormIssue(field, value: value) {
                Label(issue, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .toggle:
            Toggle(field.label, isOn: Binding(get: { value == .bool(true) }, set: { set(.bool($0)) }))
        case .text:
            TextField(field.label, text: Binding(get: { value?.text ?? "" }, set: { set($0.isEmpty ? empty : .string($0)) }))
        case .number(let minimum?, let maximum?, true) where maximum - minimum <= 20:
            choice(Array(Int(minimum)...Int(maximum)).map { RecipeFormOption(value: "\($0)") }, number: true)
        case .number(_, _, let integer):
            TextField(field.label, value: number(integer: integer), format: .number)
        case .choice(let options):
            choice(options, number: false)
        case .choices(let options):
            VStack(alignment: .leading, spacing: 6) {
                Text(field.label)
                if options.isEmpty {
                    Text("No hay ninguno").foregroundStyle(.secondary)
                }
                ForEach(options, id: \.value) { option in
                    Toggle(option.label, isOn: chosen(option.value))
                }
            }
        case .group:
            EmptyView()
        }
    }

    private func choice(_ options: [RecipeFormOption], number: Bool) -> some View {
        let current = number ? value.flatMap(numberText) : value?.text
        let stale = current.flatMap { current in options.contains { $0.value == current } ? nil : current }
        return Picker(field.label, selection: Binding(
            get: { current },
            set: { picked in set(picked.map { number ? Double($0).map(DataValue.number) : .string($0) } ?? empty) }
        )) {
            if field.nullable || current == nil {
                Text("—").tag(String?.none)
            }
            ForEach(options, id: \.value) { option in
                Text(option.label).tag(String?.some(option.value))
            }
            if let stale {
                Text("\(stale) (ya no está)").tag(String?.some(stale))
            }
        }
    }

    private func number(integer: Bool) -> Binding<Double?> {
        Binding(
            get: { if case .number(let number) = value { number } else { nil } },
            set: { set($0.map { .number(integer ? $0.rounded() : $0) } ?? empty) })
    }

    private func chosen(_ option: String) -> Binding<Bool> {
        Binding(
            get: { (value.flatMap(items) ?? []).contains(.string(option)) },
            set: { on in
                var picked = (value.flatMap(items) ?? []).filter { $0 != .string(option) }
                if on { picked.append(.string(option)) }
                set(.array(picked))
            })
    }

    private func set(_ new: DataValue?) {
        values = values.setting(new, at: path)
    }
}

private func items(_ value: DataValue) -> [DataValue]? {
    guard case .array(let items) = value else { return nil }
    return items
}

private func numberText(_ value: DataValue) -> String? {
    guard case .number(let number) = value else { return nil }
    return number == number.rounded() ? "\(Int(number))" : "\(number)"
}
