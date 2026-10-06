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

    public static func unpublish(from kind: Connector.Kind) -> String {
        switch kind {
        case .notion:
            "La página se archiva en \(kind.label) (se puede restaurar desde su papelera). La grabación y sus transcripciones se quedan en la biblioteca."
        case .okf:
            "Se borran sus ficheros .md de la carpeta del bundle y se anota la baja en el registro. La grabación y sus transcripciones se quedan en la biblioteca."
        case .plugin:
            "El plugin retira lo publicado en su destino. La grabación y sus transcripciones se quedan en la biblioteca."
        }
    }

    public static let discard =
        "Desaparecen la fila, sus transcripciones y la copia de audio. El fichero original en su carpeta no se toca, pero la grabacion no volvera a aparecer en la biblioteca."
}

public enum ConnectorText {
    public static func removal(of kind: Connector.Kind) -> String {
        switch kind {
        case .notion:
            "Se borran su configuración y su token de Notion; tendrías que volver a pegarlo. Las páginas ya publicadas siguen en Notion."
        case .okf:
            "Se borra su configuración. Los ficheros ya escritos siguen en la carpeta."
        case .plugin:
            "Se borran su configuración y sus claves. Lo ya publicado sigue en su destino."
        }
    }
}
