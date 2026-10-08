import EscribaCore
import EscribaModel
import SwiftUI

struct ReprocessSheet: View {
    let settings: AppSettings
    let listing: [RecipeListing]
    let onRun: (RecipeChoice) -> Void
    let onCancel: () -> Void
    @State private var recipe: String
    @State private var parameters: DefaultRecipeSettings?
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
        let book = settings.recipeBook
        _recipe = State(initialValue: book.defaultKey)
        _parameters = State(initialValue: book.form(book.defaultKey)?.settings)
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
                    .onChange(of: recipe) { _, key in parameters = settings.recipeBook.form(key)?.settings }
                } footer: {
                    Text(parameters == nil && codeForm == nil
                        ? "Es de código: hace lo que diga su código."
                        : "Los cambios de abajo valen solo para esta vez; la receta no cambia.")
                }
                if let parameters = Binding($parameters) {
                    RecipeParametersFields(settings: settings, parameters: parameters)
                } else if let codeForm {
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
                    onRun(RecipeChoice(recipe: recipe, parameters: parameters, values: oneTimeValues))
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
        .task(id: recipe) {
            form = nil
            let loaded = await forms?.load(recipe)
            if case .form(let loadedForm)? = loaded {
                values = recipeFormValues(loadedForm, saved: savedRecipeValues(settings.recipeBook, recipe))
            }
            form = loaded
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
