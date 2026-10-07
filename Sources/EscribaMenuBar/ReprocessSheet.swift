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
                    Text(parameters == nil
                        ? "Es de código: hace lo que diga su código."
                        : "Los cambios de abajo valen solo para esta vez; la receta no cambia.")
                }
                if let parameters = Binding($parameters) {
                    RecipeParametersFields(settings: settings, parameters: parameters)
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
                Button("Reprocesar") { onRun(RecipeChoice(recipe: recipe, parameters: parameters)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 520)
    }
}
