import EscribaCore
import EscribaModel
import SwiftUI

struct ReprocessSheet: View {
    let settings: AppSettings
    let listing: [RecipeListing]
    let onRun: (RecipeChoice) -> Void
    let onCancel: () -> Void
    @State private var recipe: String
    @State private var form: RecipeFormLoad?
    @State private var values: DataValue = .object([])
    @Environment(\.recipeForms) private var forms

    init(
        settings: AppSettings, listing: [RecipeListing], onRun: @escaping (RecipeChoice) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.settings = settings
        self.listing = listing
        self.onRun = onRun
        self.onCancel = onCancel
        _recipe = State(initialValue: settings.recipeBook.defaultKey)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reprocesar con una receta")
                .font(.headline)
            Form {
                Section {
                    Picker("Receta", selection: $recipe) {
                        ForEach(listing) { recipe in
                            Text(recipe.isDefault ? "\(recipe.name) (por defecto)" : recipe.name).tag(recipe.key)
                        }
                    }
                } footer: {
                    Text(footer)
                }
                if let codeForm {
                    RecipeFormSections(form: codeForm, values: $values)
                } else if case .problem(let problem)? = form {
                    Section("Parámetros") {
                        Text(problem)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 380)
            Text("La receta hace su recorrido entero. Si no cambian los criterios de transcripción, aprovecha la transcripción que ya hay; si cambian, sale una versión nueva y la anterior se conserva. Publica donde diga la receta y regenera las páginas que ya existían.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancelar", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Reprocesar") {
                    onRun(RecipeChoice(recipe: recipe, values: oneTimeValues))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
        .task(id: recipe) {
            form = nil
            let loaded = await forms?.load(recipe) ?? .problem("las recetas no arrancan en este Mac")
            if case .form(let loadedForm) = loaded {
                values = recipeFormValues(loadedForm, saved: savedRecipeValues(settings.recipeBook, recipe))
            }
            form = loaded
        }
    }

    private var footer: String {
        switch form {
        case nil: "Leyendo sus parámetros…"
        case .noForm?: "No tiene parámetros: hace lo que diga su código."
        case .form?: "Los cambios de abajo valen solo para esta vez; la receta no cambia."
        case .problem?: "Sus parámetros no se pueden pintar: se usan los guardados."
        }
    }

    private var codeForm: RecipeForm? {
        guard case .form(let form)? = form else { return nil }
        return form
    }

    private var oneTimeValues: String? {
        codeForm.map { dataText(recipeFormOverrides($0, values: values) ?? .object([])) }
    }
}
