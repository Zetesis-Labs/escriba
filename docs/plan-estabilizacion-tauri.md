# Plan de estabilización de Escriba Tauri

Desarrolla el ADR-0004. Cada fase cierra con evidencia que Rubén ve en pantalla
y con un PR por bloque cerrado. El orden lo marca lo que más duele: primero que
transcriba, después que haga lo mismo que Swift, después todo lo demás.

## Fase 0. Ordenar el tablero

- Pila de PRs: Personas (#23) contra `main`, #21 sobre Personas, #22 sobre #21.
  #21 y #22 en borrador. Nada de merges.
- ADR-0004 y este plan.
- Ninguna función nueva en Tauri hasta cerrar las puertas.

## Fase 1. Transcribe de punta a punta (puerta 1)

Guion que ejecuta Rubén en la app instalada, sin acceso total al disco:

1. Abrir Escriba Tauri. La biblioteca aparece y no hay trabajos fallidos.
2. Grabar una nota en Notas de Voz desde el iPhone o el Mac.
3. La nota aparece sola en la Biblioteca y pasa a «procesando».
4. Termina con transcripción y resumen visibles.
5. Cerrar la app con Cmd+Q y volver a abrirla.
6. La carpeta sigue vigilada sin volver a autorizarla y la nota no se procesa otra vez.
7. Reprocesar la nota a mano crea una versión nueva.

Además, en el equipo de desarrollo:

- La prueba con motores reales (`scripts.rs`, marcada `#[ignore]`) pasa con
  Whisper y Apple Intelligence instalados y tiene su script.
- Mismo audio en Swift y en Tauri: tiempo de transcripción, CPU en reposo y
  memoria tras cinco minutos. Si Tauri pierde por más de un 20 %, se investiga.

## Fase 2. Paridad y auditoría (puertas 2 y 3)

- `docs/paridad-swift-tauri.md`: inventario de la app SwiftUI sección por
  sección, su equivalente en Tauri y la prueba. Columna aparte con lo que Tauri
  añade, para que Rubén decida qué se queda.
- `docs/auditoria-decisiones-tauri.md`: cada decisión cerrada del CLAUDE.md con
  el código o el test de Tauri que la cumple, o marcada como incumplida.
- Lo incumplido o lo que falta se convierte en la lista de trabajo de la fase 3.

## Fase 3. Cerrar lo que falta

Por orden de daño:

- Lo incumplido de la auditoría que afecte a datos o a publicación.
- Transporte: la lista de grabaciones viaja sin versiones ni segmentos y el
  detalle se pide al seleccionar; eventos en vez de sondeo cada 15 s.
- Personas, con las huellas sin salir de Rust ni del Mac.
- Editor de plantillas con pastillas y «/» en el cursor sobre los campos del
  destino. Desbloquea #21: hoy la app SwiftUI de #21 no lo tiene.
- Notion contra el servicio real con audio sintético: crear, regenerar,
  retirar, más de 100 bloques y 429.

## Fase 4. Código a las reglas de la casa (puerta 4)

- Rust: structs de serde para grabación, versión, trabajo y ajustes; errores
  tipados con «reintentable» como variante; `store.rs` partido por entidad; sin
  `unwrap` fuera de tests.
- TypeScript: `App.tsx` partido por sección; controles propios en lugar de los
  de WebKit.

## Fase 5. Tamaño y empaquetado (puerta 5)

- Perfil de release con `strip`, `lto` y `codegen-units = 1`; medir antes y después.
- Decidir con cifras si el ejecutable Deno se queda.
- Notarizar una vez con los binarios externos.

## Fase 6. Documentación

- CLAUDE.md con una sección por app.
- «El núcleo viaja»: o vuelve la sonda WASI al CI o se retira la frase.
- ADR que declara la sustitución, cuando pasen las cinco puertas.
