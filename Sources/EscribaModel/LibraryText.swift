import Foundation
import EscribaStore

public func librarySummary(of statuses: [RecordingStatus]) -> String {
    let pending = statuses.count(where: { $0 != .done })
    let total = "\(statuses.count) en la biblioteca"
    return pending == 0 ? total : "\(total), \(pending) sin transcribir"
}

public enum RowActionText {
    public static func removeAudio(originalExists: Bool) -> String {
        originalExists
            ? "Se borra la copia de la biblioteca; el original en su carpeta se conserva y las transcripciones se quedan."
            : "El original ya no existe: sin la copia, el audio se pierde del todo. Las transcripciones se quedan."
    }

    public static let discard =
        "Desaparecen la fila, sus transcripciones y la copia de audio. El fichero original en su carpeta no se toca, pero la grabacion no volvera a aparecer en la biblioteca."
}
