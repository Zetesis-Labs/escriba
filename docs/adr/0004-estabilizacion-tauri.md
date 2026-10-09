# Tauri sustituye a SwiftUI solo al pasar sus puertas

Estado: aceptado por Rubén el 2026-10-09. Modifica el ADR-0003.

El ADR-0003 fija Tauri y SurrealDB como destino. Este ADR fija cuándo se llega.
El encargo original era igualar las capacidades de la app SwiftUI. La rama
añadió funciones que Swift no tiene y dejó sin comprobar la transcripción, que
es lo único que el producto no puede dejar de hacer. Por eso la migración no se
declara hecha por decisión, sino por evidencia.

## Puertas

1. **Transcribe de punta a punta en la app instalada.** Una nota nueva de una
   carpeta vigilada se transcribe con WhisperKit, se resume, se ve en la
   Biblioteca, sobrevive a un reinicio de la app y no se vuelve a procesar.
   Lo comprueba Rubén en pantalla con el guion de
   `docs/plan-estabilizacion-tauri.md`. Los tests no bastan.
2. **Paridad con la app SwiftUI.** `docs/paridad-swift-tauri.md` lista cada
   capacidad de Swift con su equivalente en Tauri y la prueba de que funciona.
   Lo que Tauri tiene y Swift no se lista aparte; cada función sobrante se queda
   solo si Rubén la aprueba.
3. **Cada decisión cerrada del CLAUDE.md, comprobada en el código.**
   `docs/auditoria-decisiones-tauri.md` cita para cada decisión el fichero o el
   test de Tauri que la cumple, o la marca como incumplida.
4. **El código cumple las reglas de la casa**: tipos en lugar de JSON genérico,
   errores tipados, decisiones puras con test y ficheros de tamaño razonable.
5. **Tamaño y empaquetado medidos**: binario de release optimizado y
   notarización probada.

## Reglas mientras tanto

- No entra ninguna función nueva en Tauri. Solo cambios que acercan a una puerta.
- La app SwiftUI sigue siendo la que se usa a diario y no pierde nada por la
  migración. Un cambio de comportamiento entra en las dos o en ninguna.
- La estabilización la lleva Claude por encargo de Rubén. Ningún otro agente
  trabaja en `spike/conectores-js-npm` ni en `feat/tauri-dual-app`.
- Cuando pasen las cinco puertas, un ADR nuevo declara la sustitución y fija
  cuándo se retira la app SwiftUI.
