# Acceso selectivo a carpetas en macOS

Investigación breve para el caso de Escriba Tauri en macOS 26. No cambia la
app ni establece todavía una decisión de producto.

## Hallazgos

- **La app Tauri puede pedir al usuario que elija una carpeta.** Apple documenta
  `NSOpenPanel` (configurado para permitir directorios) y explica que, en una
  app con App Sandbox y el entitlement de archivos seleccionados, macOS amplía
  el acceso a la URL elegida y a su jerarquía. El URL tiene acceso con ámbito
  de seguridad durante la sesión. Para conservarlo tras reiniciar, se guarda un
  bookmark con ámbito de seguridad, se resuelve al iniciar y se llama a
  `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
  [Apple: acceso a archivos desde App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
  · [Apple: NSOpenPanel](https://developer.apple.com/documentation/appkit/nsopenpanel)

- **Esto es una extensión de App Sandbox, no una autorización general que
  sustituya Full Disk Access.** Apple DTS separa la sandbox estática, sus
  extensiones dinámicas por elección del usuario y MAC/TCC. El permiso del
  panel permite el acceso dentro de la jerarquía elegida, pero no elimina todas
  las protecciones MAC de ubicaciones contenidas;
  como ejemplo, acceso concedido a `~/Library` no da acceso a `~/Library/Mail`
  si esa ubicación está protegida por MAC. [Apple DTS: permisos del sistema de
  archivos](https://developer.apple.com/forums/thread/678819)

- **Hay evidencia directa de Apple DTS para Voice Memos.** DTS confirma que
  MAC bloquea el acceso directo al contenedor
  `group.com.apple.VoiceMemos.shared`, pero demuestra que `NSOpenPanel` puede
  elegir un archivo `.m4a` dentro de `Recordings` y que la app puede leerlo sin
  FDA. También confirma que funciona con App Sandbox si la app declara
  `com.apple.security.files.user-selected.read-only` y llama a
  `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()`.
  [Apple DTS: acceso a carpeta de otra app](https://developer.apple.com/forums/thread/768040?answerId=813217022)

- **El alcance demostrado es un archivo individual, no el caso completo de
  Escriba.** La respuesta de DTS no prueba elegir la carpeta `Recordings` como
  directorio, enumerarla, vigilarla recursivamente con FSEvents, ni conservar
  autorización tras cerrar y volver a abrir la app. Apple documenta en general
  que seleccionar una carpeta amplía acceso a su jerarquía y que bookmarks con
  ámbito sirven para restaurarlo tras relanzar; al combinarlo con la protección
  MAC de Voice Memos, el resultado para enumeración y vigilancia de esa carpeta
  aún debe probarse. [Apple: acceso a archivos desde App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
  · [Apple DTS: permisos del sistema de archivos](https://developer.apple.com/forums/thread/678819)

- **El `EPERM` no identifica por sí solo la causa.** Apple documenta que puede
  corresponder a restricciones MAC, SIP o protección de datos, además de otros
  controles del sistema. Hay que capturar el error subyacente y revisar los
  registros de sandbox/TCC para atribuirlo. [Apple: diagnóstico de acceso a
  archivos](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
  · [Apple DTS](https://developer.apple.com/forums/thread/678819)

## Situación inicial y límites

`apps/tauri/src-tauri/Entitlements.plist` solo declara
`com.apple.security.device.audio-input`; no declara
`com.apple.security.app-sandbox` ni el entitlement de archivos seleccionados.
No se inspeccionó la firma del `.app` instalado.

Antes de este cambio, `chooseFolder()` llamaba a `open({ directory: true })` y
`addFolder()` guardaba sólo el path en ajustes, sin bookmark.
El flujo pide una carpeta, mientras que el caso confirmado por DTS
selecciona un archivo. Estas son diferencias relevantes para el acceso en
reinicios y para la vigilancia continua.

## Implementación y pruebas del cambio

`watch_folder_authorize` utiliza `NSOpenPanel` desde Rust y conserva un bookmark
ordinario con ámbito implícito en SurrealDB. Los bytes nunca llegan a la WebView
ni a las recetas. Se resuelve y mantiene el acceso antes de vigilar, se actualiza
la ruta cuando macOS identifica una carpeta movida y se pasa el bookmark al
adaptador Apple cuando necesita materializar un audio de iCloud.

Las pruebas con carpetas sintéticas comprueban restauración en un proceso nuevo,
renovación tras mover la carpeta, persistencia en SurrealKV, ocultación de bytes
en las respuestas y acceso desde el adaptador Swift. No prueban por sí solas
el consentimiento de TCC para Notas de Voz. Rubén retiró Acceso total al disco
para realizar esa comprobación con el selector de la aplicación instalada.

## Persistencia en la configuración actual sin App Sandbox

- En una respuesta de Apple DTS sobre macOS Catalina, DTS confirma que cuando
  una app **sin App Sandbox** lleva al usuario a seleccionar en `NSOpenPanel`
  un elemento protegido, macOS infiere consentimiento; el autor del caso
  observó que el permiso persistía entre lanzamientos y reinstalaciones, sin
  bookmark. DTS observó que el mecanismo parecía registrarse en el atributo
  `com.apple.macl`. Es evidencia directa del comportamiento de selección
  implícita de TCC/MAC, aunque el caso documentado es Catalina y no garantiza
  por sí solo los detalles de macOS 26 ni la enumeración de Voice Memos.
  [Apple DTS: consentimiento inferido en apps sin sandbox](https://developer.apple.com/forums/thread/124121?answerId=391281022)
- Por eso, para la app actual, la opción a probar primero es seguir usando el
  panel nativo para que el usuario elija `Recordings` y dejar que macOS registre
  ese acto de usuario. El path persistido puede servir como referencia, pero
  no es en sí el permiso; no hace falta añadir un bookmark explícito con
  `withSecurityScope` a una app no sandboxed basándose en la documentación de
  bookmarks de App Sandbox.
- Apple documenta los bookmarks **explícitamente** security-scoped como
  mecanismo de persistencia de App Sandbox. Para ellos, `withSecurityScope`
  requiere habilitar los entitlements de bookmarks app-scope o document-scope;
  el de app-scope liga el bookmark a la identidad firmante que lo creó. Un
  bookmark ordinario también puede llevar un ámbito implícito temporal, pero
  Apple dice que ese ámbito dura como máximo hasta el reinicio: no equivale a
  autorización persistente. [Apple: bookmarks para App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
  · [Apple: entitlement de bookmarks](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access)
  · [Apple: ámbito implícito temporal](https://developer.apple.com/documentation/foundation/nsurl/bookmarkcreationoptions/withoutimplicitsecurityscope)

## Impacto de activar App Sandbox

No activar `com.apple.security.app-sandbox` globalmente como parte de la
solución inicial de acceso a carpetas. Cambiaría la frontera de seguridad de
toda la app; la ruta más acotada es primero probar el panel y el consentimiento
implícito que corresponde al empaquetado no sandboxed actual. No es una
prohibición de evaluar App Sandbox después.

El coste de esa evaluación es real: hoy el paquete trae tres sidecars
(`EscribaNativeHost`, `escriba-esbuild`, `escriba-runtime`). Apple dice que los
procesos hijos heredan la sandbox del proceso padre y que el acceso concedido
por una selección de panel es una extensión dinámica ligada al proceso; el
acceso persistente entre procesos sandboxed se pasa con bookmarks. Por ello,
si el acceso a `Recordings` se usa desde `EscribaNativeHost` o una tarea hija,
habría que diseñar y validar dónde se resuelve el bookmark y dónde se mantiene
abierta su scope, además de probar los sidecars firmados y empaquetados.
`escriba-esbuild` escribe el paquete compilado del proyecto de recetas del
usuario: bajo sandbox habría que validar también lectura y escritura en esa
carpeta seleccionada. Apple prohíbe ejecutar programas desde ubicaciones
seleccionadas salvo que se otorgue el entitlement específico para ejecutables;
los sidecars actuales están empaquetados con la app, pero su funcionamiento
bajo sandbox aún debe probarse. [Apple DTS: extensiones ligadas al proceso e
herencia](https://developer.apple.com/forums/thread/678819)
· [Apple: ejecución en ubicaciones elegidas](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)

## Qué probar para decidir

1. En el empaquetado no sandboxed actual, elegir `Recordings` con el panel y
   verificar enumeración, lectura, cambios nuevos y FSEvents; cerrar/relanzar y
   repetir sin FDA. Esto confirma si el consentimiento implícito cubre el flujo
   de la app en macOS 26.
2. Si se evalúa App Sandbox por separado, habilitar solo los entitlements
   necesarios para selección de carpeta, scope de solo lectura y bookmarks;
   pasar/resolver el bookmark en el proceso que vigila/lee y verificar los tres
   sidecars, incluido `escriba-esbuild` escribiendo en el proyecto seleccionado.
3. En ambas variantes usar firma estable y registrar `EPERM` y logs de
   `sandboxd`/TCC. Comparar con FDA solo si falla el flujo completo.

La selección de un archivo concreto de Voice Memos sin FDA está confirmada por
Apple DTS. Apple DTS también documenta consentimiento implícito persistente
tras seleccionar archivos/carpetas protegidos en apps no sandboxed (caso
Catalina). Para la función de Escriba —elegir `Recordings`, enumerar y vigilar
la carpeta, y conservar acceso tras reiniciar en macOS 26— sigue pendiente la
prueba integrada. Mantener de momento el empaquetado no sandboxed y validar su
flujo completo antes de decidir si compensa migrar toda la app a App Sandbox.
