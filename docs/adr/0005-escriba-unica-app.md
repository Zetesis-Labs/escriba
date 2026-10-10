# Escriba es la única aplicación de escritorio

Aceptado por Rubén el 2026-10-10. Sustituye la coexistencia temporal fijada por
los ADR-0002, ADR-0003 y ADR-0004: la aplicación actual se llama **Escriba** y se
instala como **Escriba.app**. Se retiran la interfaz SwiftUI, su empaquetado y el
importador de su biblioteca. Swift permanece como adaptador nativo de Apple;
Tauri es una dependencia técnica, no una edición del producto.

Se conserva `dev.zetesis.escriba.tauri` como identificador técnico estable para
mantener los datos y permisos de las instalaciones actuales. La biblioteca,
credenciales y preferencias existentes no se trasladan ni se reinician. Los
formatos ya guardados siguen siendo legibles. Los módulos necesarios para el
adaptador y el CLI se conservan; la referencia SwiftUI permanece en Git
(`2e8614b` para paridad), fuera de los productos activos.

Esta decisión retira la coexistencia; no certifica las comprobaciones de calidad
que siguen pendientes en `docs/pendiente-tauri.md`: limpieza de Rust, medidas de
tamaño y memoria, notarización y validaciones manuales de cierre.
