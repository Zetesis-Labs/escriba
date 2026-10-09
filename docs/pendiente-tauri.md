# Lo que queda de la estabilización de Escriba Tauri

Encargo de Rubén del 2026-10-09 para Codex. Sustituye a cualquier plan anterior
de Codex sobre Tauri. Léelo entero antes de tocar nada; cada apartado dice qué
hacer, dónde, con qué textos y cómo se comprueba.

## 0. La única directriz

**La app Tauri tiene que tener la misma interfaz y el mismo comportamiento que
la app SwiftUI de `feat/personas` (commit `2e8614b`).** Las mismas secciones,
textos, menús, hojas, alertas, atajos y flujos. Nada más y nada menos.

- Si Swift no lo tiene, no se hace. No se añade ninguna función, opción,
  filtro, ajuste ni «mejora». Lo que Rubén ya aprobó como añadido de Tauri está
  en `docs/paridad-swift-tauri.md` («Lo que añadió Codex») y no se amplía.
- Ante cualquier duda de texto o de flujo, se abre el fichero Swift citado y se
  copia. Los textos con faltas de Swift («transcripcion», «Anadir») se escriben
  con su tilde; es la única desviación permitida.
- La referencia Swift se lee con `git show 2e8614b:<ruta>` desde el worktree,
  porque en la rama actual algunos targets Swift (`EscribaNotion`, `EscribaOKF`)
  ya no existen. También vale `~/Developer/escriba`, que está en `feat/personas`.

Está **prohibido**, por decisión de Rubén:

- Buscar o filtrar en la biblioteca (lo diseñará él más adelante).
- Velocidad de reproducción.
- React Aria, shadcn o cualquier librería de componentes. La interfaz es React
  sin librerías, con los controles propios de `apps/tauri/src/mac/` y los menús,
  alertas y diálogos nativos de Tauri (`src/mac/native.ts`).
- Deno para las recetas: va Bun (apartado 8).
- Reintroducir nada de la interfaz anterior de Codex (borrada en `33d12d4`).

## 1. Cómo se trabaja

- Rama `feat/tauri-dual-app`, worktree `~/Developer/_worktrees/escriba-tauri`.
  Pila de PRs: #23 (`feat/personas` → `main`) ← #21 (`spike/conectores-js-npm`)
  ← #22 (esta rama). Todos en borrador. **Nunca hagas push, merge ni cambies un
  PR sin que Rubén lo pida.** El push pendiente de #21 lo lanza él.
- Antes de empezar lee `CLAUDE.md`, `docs/adr/0004-estabilizacion-tauri.md`,
  `docs/paridad-swift-tauri.md` y `docs/auditoria-decisiones-tauri.md`.
- Tests primero. Toda decisión va en una función pura con test: en TypeScript
  en `apps/tauri/src/core/` con su test en `apps/tauri/tests/core/`, traduciendo
  los tests Swift equivalentes; en Rust, en su módulo con `#[cfg(test)]`. Los
  nombres de test describen el comportamiento en castellano.
- Sin comentarios salvo un porqué no obvio de una línea. Nombres claros y
  funciones pequeñas.
- Un commit por cosa, convencional y en castellano (`feat(tauri): …`,
  `fix(tauri): …`). **Sin trailers de IA** (`Co-Authored-By` ni similares).
- Una sección está «hecha» cuando funciona en la app instalada y Rubén la ha
  visto. Motor más tests no basta. Marca la casilla en
  `docs/paridad-swift-tauri.md` solo cuando él lo confirme.
- No toques el código ni reinstales mientras Rubén prueba sin avisarle antes.

Seguridad, sin excepciones:

- Nunca publiques notas de voz reales en Notion. Para probar en vivo, audio
  sintético (`say -o x.aiff "texto" && afconvert x.aiff x.m4a -f m4af -d aac`).
- Nunca imprimas el texto de una nota en logs, salidas de comandos ni PRs. Si
  necesitas inspeccionar la base de Rubén, copia `library.surrealkv` a un
  directorio temporal y saca solo recuentos, estados e ids.
- Los tokens nunca llegan al JavaScript: viven en ficheros 0600 y los inyecta
  Rust (`connector_http`). Las huellas de voz nunca salen de Rust ni del Mac.

### Comandos

```bash
cd ~/Developer/_worktrees/escriba-tauri/apps/tauri
npx tsc --noEmit -p .                      # tipos
npx vitest run                             # tests TS (sidecar.test.ts falla si el Deno 2.1.9 va primero en el PATH; con el 2.6.9 de Homebrew pasa)
cd src-tauri && cargo test --lib && cargo clippy --all-targets && cargo fmt --check
cd ~/Developer/_worktrees/escriba-tauri && ./scripts/build-tauri.sh --release
export TOOLCHAINS=org.swift.640202609131a && swift test --filter EscribaNativeHostTests   # host nativo
```

Instalar (cierra la app, guarda **solo** la versión anterior y abre la nueva):

```bash
cd ~/Developer/_worktrees/escriba-tauri
osascript -e 'quit app "Escriba Tauri"'; sleep 3
APP="apps/tauri/src-tauri/target/release/bundle/macos/Escriba Tauri.app"; T="/Applications/Escriba Tauri.app"
codesign --verify --deep --strict "$APP" && rm -rf ".build/Escriba Tauri-anterior.app" \
  && mv "$T" ".build/Escriba Tauri-anterior.app" && ditto "$APP" "$T" && open "$T"
```

Capturas sin tocar la app de Rubén: `npx vite --port 5199` y abrir
`http://127.0.0.1:5199/?demo=1` (datos de `src/app/demo.ts`). El panel de
grabación se ve en `?panel=recording&demo=1`.

### Trampas ya conocidas

- **Todo lo que toca la barra de menús (bandejas, `NSStatusItem`, menús) va en
  el hilo principal** (`app.run_on_main_thread`). Soltar un `TrayIcon` desde un
  hilo de tokio tumbó la app al salir (`9a275fe`).
- Cada ventana nueva de Tauri tiene que estar en `capabilities/main.json`
  (`windows`), o sus `listen`/`invoke` fallan en silencio.
- `settings_save` solo guarda las claves de `SETTABLE` en `store.rs`.
- La biblioteca viaja ligera (`library()` en Rust): sin segmentos, texto
  recortado y huellas de paquete en vez de los paquetes. El detalle completo se
  pide con `recording_detail`. `config_save` conserva `bundle` y `program`
  aunque el cliente no los mande.
- La Biblioteca está siempre montada (oculta con `hidden`); no la desmontes al
  cambiar de sección o se pierde la fluidez.
- El color de acento real lo da Rust (`system_appearance`), no WebKit.

## 2. Estado al traspasar

Rehecho igual que en Swift e instalado: ventana y barra lateral, Biblioteca con
su detalle, STT, LLMs, Recetas, Registro, Ajustes, el panel flotante de
grabación, la barra de menús con su menú y ⌘N. La interfaz anterior de Codex
está borrada; **Conectores muestra un aviso** hasta que se haga el apartado 3.

Rubén aún no ha confirmado en pantalla: el panel de grabación (incluido salir
con ⌘Q mientras graba, arreglado en `9a275fe`), la barra de menús y Ajustes. Del
guion de la puerta 1 faltan los pasos 5 a 7 (cerrar y abrir sin que se
reprocese, y reprocesar a mano).

## 3. Conectores

Decisión de Rubén del 2026-10-09: **la configuración de cada destino vive en la
app, como en Swift**. El editor guarda la configuración como datos y la librería
`packages/conectores` la interpreta al publicar. Los destinos escritos en código
en el proyecto de recetas siguen funcionando, pero no aparecen en esta lista.

Referencias Swift: `Sources/EscribaMenuBar/SettingsView.swift` (`ConnectorsPane`
y `NotionEditor`), `OKFEditor.swift`, `TokenEditor.swift`,
`Sources/EscribaModel/{Connector,ConnectorsModel,NotionModel,OKFModel,LibraryText}.swift`,
`Sources/EscribaCore/TextTemplate.swift`,
`Sources/EscribaNotion/{NotionColumns,NotionPreview}.swift`,
`Sources/EscribaOKF/{OKFNote,OKFPreview}.swift`. Tests a traducir:
`Tests/EscribaCoreTests/PlantillaTextoTests.swift`,
`Tests/EscribaNotionTests/{MapeoTests,VistaPreviaTests}.swift`,
`Tests/EscribaOKFTests/VistaPreviaTests.swift`,
`Tests/EscribaModelTests/{ConectoresTests,ConectorOKFTests,NotionModelTests}.swift`.

### 3.1 Modelo de datos

Un conector de Swift (`id`, `name`, `kind`, `enabled`, `notion` u `okf`) es en
Tauri **una cuenta y un destino con el mismo `id`**:

- `accounts`: `{id, name, provider: "notion"|"okf", enabled: true, origin: "https://api.notion.com"}`
  para Notion, o `{…, folder}` para OKF. `enabled` de la cuenta queda siempre a
  `true`.
- `destinations`: `{id, name, provider, account: id, enabled, configuration}`,
  **sin `program`**, así que publica con el programa de serie de la librería.
  `enabled` es «Publicar cada transcripción nueva» / «Exportar cada transcripción
  nueva». `configuration` es `{source, columns, body}` en Notion y
  `{folder, documents}` en OKF, el mismo esquema que `notionSchema` y
  `okfSchema` de `packages/conectores`.
- El token se guarda con `credential_save {id, value}` (fichero 0600 en
  `secrets/`). «Desconectar» lo borra.

Cambios de motor necesarios:

1. `catalog::install` (`src-tauri/src/catalog.rs`) hoy **sustituye todos los
   destinos** por los del proyecto al compilar. Tiene que conservar los
   destinos sin `program` (los de la app) y sustituir solo los del proyecto.
   Test: compilar un proyecto no borra un destino de la app.
2. Quitar un conector borra su cuenta, su destino y su token, y lo quita de los
   valores de las recetas de formulario (`conectores` de «Por defecto»), igual
   que `ConnectorsModel.remove` y `RecipeBook.forgettingConnector`. Las
   publicaciones ya hechas se quedan.
3. Exporta `suggestedColumns` en `packages/conectores/src/notion.ts`, reconstruye
   `dist` (`npm run build` en el paquete) y el programa de serie que usa la app.

### 3.2 Pantalla

Lista y detalle como `ConnectorsPane`: lista de 230 px con un círculo verde
relleno si el conector está vivo (`enabled` y listo) o gris vacío si no, el
nombre y el subtítulo («Sin base elegida» o el nombre de la base en Notion;
«Sin carpeta elegida» o la carpeta abreviada con `~` en OKF). Barra inferior con
«+», que abre un menú nativo con «Notion» y «OKF», y «−». Al añadir, el nombre
es `nextConnectorName` («Notion», «Notion 2»…) y se selecciona. Sin selección:
«Sin conector elegido» / «Añade uno con + o elige uno de la lista.». Quitar
pide confirmación nativa «¿Quitar «nombre»?» con el texto de
`ConnectorText.removal`:

- Notion: «Se borran su configuración y su token de Notion; tendrías que volver a pegarlo. Las páginas ya publicadas siguen en Notion.»
- OKF: «Se borra su configuración. Los ficheros ya escritos siguen en la carpeta.»

Los dos editores trabajan sobre un **borrador**. La barra inferior muestra
«Cambios sin guardar» cuando el borrador difiere de lo guardado, más
«Descartar» y «Guardar» (Guardar con Intro como acción por defecto).

**Notion** (`NotionEditor`), formulario agrupado:

1. «Nombre», interruptor «Publicar cada transcripción nueva» (desactivado
   mientras no esté listo) y debajo el aviso de lo que falta o, si está listo,
   «Corregir hablantes o reprocesar regenera la página ya publicada.». Lo que
   falta, por orden: «Pega el token de tu integración de Notion.», «Elige la
   base donde guardar.», y `notionProblem` de la librería.
2. «Conexión con Notion»: campo seguro «Token de la integración», botón
   «Conectar» (o «Actualizar bases y columnas» si ya hay bases), indicador de
   trabajo y, si hay token, «Desconectar» en rojo. Error en rojo. Pie: «En
   Notion: Ajustes → Conexiones → nueva conexión con «Token de acceso», dale
   acceso a las bases que quieras y pega aquí el token. Si añades columnas a la
   base, pulsa «Actualizar».». Si Notion no devuelve ninguna base: «La
   integración no tiene acceso a ninguna base. Compártele una desde Notion.».
   «Conectar» guarda el token y llama a `discoverDestination(id)` del runtime.
3. «Base de datos», si hay bases: selector «Guardar en» con «Sin elegir» y las
   bases. Elegir la misma base refresca sus columnas conservando lo escrito;
   elegir otra pone las columnas sugeridas (`suggestedColumns` sin las
   anteriores). Tras «Conectar», si la base elegida sigue, se refresca igual.
4. Si hay base: «Propiedades», una fila por columna escribible (`title`
   primero, luego `rich_text`, `multi_select`, `select`, `date`, `number`,
   `url`) con el nombre, el tipo en minúsculas («título», «texto», «selección
   múltiple», «selección», «fecha», «número», «URL») y un editor de plantilla
   con marcador «No se exporta». Pie: «Una fila por columna de tu base: escribe
   qué va en ella, con texto y datos. Vacía, Escriba no la toca. Las columnas de
   casilla, persona, archivo o relación no aparecen porque Escriba no escribe en
   ellas.»
5. «Cuerpo de la página»: editor multilínea, marcador «Escribe aquí. Pulsa /
   para insertar un dato.». Pie: «Escribe como en una página: # para títulos, -
   para viñetas, **negrita**. Pulsa / para insertar un dato; el dato Audio sube
   el fichero a Notion. Una línea cuyos datos salen vacíos no se escribe.»
6. «Así queda»: rejilla de propiedad y valor y, tras un separador, el texto del
   cuerpo. Pie: «Con una grabación de ejemplo. Se actualiza mientras escribes,
   antes de guardar.». Se calcula en la propia interfaz llamando a `run`
   de `@escriba/conectores` con `operation: "preview"`, `provider` y la
   configuración del borrador, **sin host**: la librería usa entonces su nota de
   ejemplo y un host sin red ni escritura. La forma de mostrar cada valor es la
   de `NotionPreview.swift` (`displayed`): título y texto unidos, selección
   múltiple separada por comas, fecha por su `start`, «—» si va vacío,
   encabezados con `#`, viñetas con «• » y el audio como «▶︎ Audio».

**OKF** (`OKFEditor`), formulario agrupado:

1. «Nombre», interruptor «Exportar cada transcripción nueva» y el aviso
   (`okfProblem`: «Elige la carpeta donde guardar las notas.», «Añade al menos
   un documento.», ««X» necesita un valor en type: OKF lo exige.», ««X» y «Y»
   escriben en la misma ruta.») en naranja, o «Corregir hablantes, reprocesar o
   resumir reescribe los ficheros ya exportados.».
2. «Carpeta del bundle»: ruta abreviada o «Sin elegir», «Mostrar en Finder» y
   «Elegir…» (diálogo de carpeta; la cuenta guarda `folder`). Pie: «Escriba
   gestiona esta carpeta como un bundle OKF: escribe los documentos, un index.md
   en cada carpeta y log.md. Si va dentro de un bundle más grande, elige una
   subcarpeta propia.»
3. «Documentos»: control segmentado con un documento por pestaña, «+» (añade
   `newDocument`: «Documento N», ruta `documentos/{{dia}}-{{titulo}}.md`,
   propiedades `type: Documento` y `title: {{titulo}}`, cuerpo `{{resumen}}`) y
   «−». Pie: «Cada grabación escribe un fichero por documento. Para enlazarlos
   entre sí, inserta el dato «Enlace a…».». Un conector nuevo empieza con
   `standardDocuments()` de la librería.
4. Del documento elegido: «Nombre» y «Ruta» (editor de plantilla en contexto
   ruta, marcador `carpeta/[Día]-[Título].md`). Pie: «La ruta dentro del bundle.
   Escribe // para insertar un dato en ella; el título se pone sin tildes ni
   signos.». «Propiedades»: una fila por propiedad con la clave en monoespaciada
   (la primera `type` fija y sin botón de quitar), el valor como editor de
   plantilla y un botón para quitarla; «Añadir propiedad». Pie: «Son el
   frontmatter del fichero: clave y valor, con texto y datos mezclados. type es
   obligatorio en OKF. Escriba añade siempre escriba_key y generated para
   reconocer sus ficheros.». «Cuerpo» multilínea con los enlaces a los otros
   documentos. Pie: «Escribe como en una página: Markdown, con # para los
   títulos. Pulsa / donde quieras para insertar un dato, o usa +. Una línea cuyos
   datos salen vacíos no se escribe.». «Así queda»: la ruta del fichero y su
   contenido en monoespaciada, del `preview` de la librería (`files`).

### 3.3 Editor de plantillas (`TokenEditor`)

Port de `TokenEditor.swift` en React, sin librerías: un `contenteditable` donde
cada dato es una pastilla no editable (`<span contenteditable="false">` con el
marcador en un atributo).

- El texto se guarda con los marcadores `{{titulo}}`, `{{enlace:<id>}}`… Lo que
  produce el editor tiene que ser exactamente lo que interpreta
  `packages/conectores/src/templates.ts`, para que las configuraciones de Swift
  pasen tal cual. Porta `TemplateToken` (marcador, etiqueta y ayuda de cada
  dato), `templatePieces`, `templateSource` y `tokenSuggestions` a
  `src/core/` con los tests de `PlantillaTextoTests.swift`.
- Catálogo: Título, Descripción, Resumen, Etiquetas, Fecha, Fecha ISO, Día,
  Hablantes, Duración, Segundos, Clave, Fichero de origen, Audio, Transcripción,
  Transcripción con tiempos, Transcripción (solo texto) y, en OKF, «Enlace a
  «documento»» de los demás documentos. En una ruta solo Día, Título y Clave.
  Un enlace a un documento que ya no existe se llama «Enlace a un documento que
  ya no existe».
- «/» abre la lista de sugerencias bajo el cursor cuando va al principio, tras
  un espacio o una pastilla, o tras «(» o «[» (en una ruta, tras «/», «-» o
  «_»). Lo escrito tras la barra filtra por el marcador o por el principio de
  cualquier palabra de la etiqueta, sin tildes ni mayúsculas, hasta 32
  caracteres y sin espacios. Flechas para moverse, Intro o Tab para elegir,
  Escape para cerrar. Cada sugerencia muestra la etiqueta y su ayuda.
- El botón «+» a la derecha del campo abre un menú nativo con todo el catálogo
  e inserta en el cursor. Ayuda: «Insertar un dato aquí (o escribe / en el
  texto)».
- Una línea: Intro no hace nada, Tab pasa al campo siguiente y los saltos de
  línea pegados se vuelven espacios. Multilínea: altura mínima de 160 px y las
  líneas con `#`, `##` o `###` en 20, 16 y 14 px en negrita.
- Copiar y cortar dejan el texto con marcadores; pegar convierte los marcadores
  en pastillas.
- Pastilla: fondo del acento al 16 %, borde del acento al 45 %, radio de 5 px,
  etiqueta en peso medio y un punto menos que el texto.

### 3.4 Importar los conectores de Swift

`merge_settings` en `src-tauri/src/migration.rs` solo entiende el formato de
#21 (`connectorAccounts` y `connectors` con `configurationJSON`). Rubén usa el
de `feat/personas`: la clave `connectors` del plist
`~/Library/Preferences/dev.ruben.escriba.plist` es un JSON con
`[{id, name, kind: "notion"|"okf", enabled, notion: {source: {id, title, databaseTitle, properties: [{name, type}]}, columns, body}, okf: {folder, documents: [{id, name, path, properties: [{id, key, value}], body}]}}]`.

- Lee los dos formatos y crea la cuenta y el destino de cada conector como en
  3.1, con `enabled` igual que en Swift. **No leas ni copies tokens**: Rubén los
  vuelve a pegar.
- Las publicaciones importadas tienen `provider: "legacy"`, `accountId: null` y
  `receipt: {state: "legacy", locator, url}`. Cuando su `destinationId` sea un
  conector importado, conviértelas: `provider` y `accountId` del conector,
  `configuration` del destino y `receipt: {version: 1, provider, locator, url, state: "published"}`.
  Esto tiene que pasar también al volver a importar sobre una biblioteca que ya
  existe (el botón de Ajustes), porque la de Rubén ya está importada. Después,
  `publicationName` de `src/library/model.ts` deja de necesitar la regla del
  host de Notion para lo convertido.
- Test con un plist sintético de cada formato y una publicación antigua que
  queda actualizable.

### 3.5 Biblioteca

En el menú de una publicación OKF faltan «Abrir el .md» y que «Mostrar en
Finder» use la ruta real del fichero (`LibraryWindow.swift`, líneas 270-290).
Hace falta un comando de Rust que abra un fichero, limitado a los que están
dentro de la carpeta de una cuenta OKF (`open_url` solo admite http y https).

Hecho cuando: Rubén crea un Notion y un OKF desde cero, ve «Así queda» cambiar
mientras escribe, guarda, publica una nota de prueba con audio sintético en una
base suya de pruebas, y sus conectores de Swift aparecen importados.

## 4. Personas

Referencias: `Sources/EscribaMenuBar/PeoplePane.swift`,
`Sources/EscribaModel/PeopleModel.swift`, `Sources/EscribaStore/People.swift`,
`Sources/EscribaCore/{Voices,Transcript}.swift`,
`Sources/EscribaEngine/Capabilities.swift` (`recognized`),
`Sources/EscribaWhisper/WhisperKitBackend.swift` (`voices`, `diarizedVoices`) y
el apartado Personas de `LibraryWindow.swift` (insignia de reconocido, «No es
X», aviso «Renombrado, pero sin aprender su voz»). Tests a traducir:
`Tests/EscribaCoreTests/VocesTests.swift`,
`Tests/EscribaEngineTests/ReconocerTests.swift`,
`Tests/EscribaStoreTests/PersonasTests.swift`,
`Tests/EscribaModelTests/{PersonasModelTests,PersonasPanelTests}.swift`.

Regla que no se rompe: **las huellas nunca llegan al JavaScript**, ni a las
recetas, ni a los conectores, ni a la exportación, ni a la interfaz. Añade un
test de Rust que falle si alguna respuesta a la WebView o al runtime contiene
`embedding`.

1. Host nativo (`Sources/EscribaNativeHost/NativeHost.swift`): `transcribe`
   devuelve también `voices` (`[{speaker, embedding, model}]`, del
   `Transcript.voices` que ya da `WhisperKitEngine` al diarizar). Método nuevo
   `diarizedVoices {audioPath}` que devuelve `{voices, spans}` para «Registrar
   voz». Tests en `Tests/EscribaNativeHostTests`.
2. Rust: tablas de personas y huellas en SurrealDB (persona con N huellas, cada
   una con modelo, origen y fecha), con las operaciones de `People.swift`:
   listar, renombrar (y juntar si el nombre ya existe), quitar una huella (y la
   persona si se queda sin huellas) y quitar una persona.
3. Reconocimiento al transcribir, en Rust, en el manejador de `transcribe`:
   porta `cosineDistance` y `recognize` (umbral 0,30, la más cercana del mismo
   modelo, uno a uno por nota) con los tests de `VocesTests.swift`. Renombra los
   segmentos reconocidos y devuelve al runtime el texto, los segmentos y las
   `recognitions` (`speaker`, `person`, `distance`), **sin las huellas**. Rust
   guarda las huellas aparte y las pega a la versión cuando llega su
   `version_save`. Solo se reconoce lo recién transcrito.
4. `controller.ts`: al reutilizar una transcripción recordada, no reutilices
   una versión diarizada sin huellas (se vuelve a diarizar) y pasa en
   `version_save` el id de la versión de origen para que Rust copie sus huellas.
5. Corregir hablantes (`src/library/operations.ts`, renombrar y fusionar, que
   ya pasan por `version_save` con backend `correccion`): renombrar o fusionar
   con alguien que ya es persona enseña esa huella a la persona en Rust. «No es
   X» deshace el reconocimiento (`forgettingRecognition`). Si no había huella
   que aprender, el aviso «Renombrado, pero sin aprender su voz».
6. Pantalla Personas igual que `PeoplePane.swift`, con «Registrar voz»: graba
   aparte de la bandeja (no crea una nota), exige 30 s de voz con los textos de
   `PeopleModel` («Solo se oyen N s de voz y hacen falta 30 s. Habla un rato
   más.», «El motor no ha dado la huella de esa voz. Prueba otra vez.»), guarda
   la huella dominante y borra la muestra.
7. La importación de Swift copia las tablas `voice` y `person` de su
   `library.sqlite` a las de Rust, sin pasar por JavaScript.

Hecho cuando: Rubén registra su voz, graba una nota a dos voces con detectar
hablantes y su nombre sale reconocido; «No es Rubén» lo deshace.

## 5. Notificaciones

Los textos de `Sources/EscribaMenuBar/Notifier.swift` y de las llamadas a
`Notifier.problem` en `AppRuntime.swift`:

- «Nota transcrita», con los primeros 80 caracteres del texto en una sola línea
  y «…» si sigue, o la clave si no hay texto. Solo si «Notificar cada
  transcripción» está activo, y sin sonido.
- «Fallo al transcribir <clave>», con el motivo.
- «El motor de transcripción no responde».
- «La receta por defecto no está disponible».
- «No puedo leer las grabaciones».
- «Carpeta vigilada inaccesible», con la ruta.
- «No se puede transcribir con <resolutor>» y «No se puede resumir con
  <resolutor>» («… Las notas se transcribirán igual.»).
- «Las recetas no arrancan».
- «No se pudo arrancar».

Los problemas siempre y con sonido. El cuerpo, como mucho 240 caracteres.
Sustituye los textos que puso Codex en `lib.rs` (`notify` y sus llamadas).

## 6. Pequeños pendientes de la interfaz

- **Hoja de reprocesar** (`src/library/LibraryView.tsx`, `ReprocessSheet`):
  falta el formulario de parámetros de la receta elegida, solo para esa vez,
  como `ReprocessSheet.swift`. El motor tiene que aceptar valores puntuales en
  `processRecording` (`options.values`) sin guardarlos en la receta.
- **Modelo de Whisper** (`src/resolvers/ResolversPane.tsx`,
  `WhisperModelSection`): la descarga tiene que mostrar «Descargando…» con su
  barra de progreso, como `SettingsView.swift:130-191`. El host nativo
  (`downloadModel`) tiene que emitir el progreso.
- Al recuperar una captura que no se llegó a guardar
  (`recover_captures` en `lib.rs`), la fecha de la nota tiene que ser la del
  fichero, no la de la recuperación.

## 7. Arreglos del motor

Por orden de daño. Cada uno con su test antes del arreglo.

1. **La receta se fija al incorporar la nota.** `import_internal` en
   `store.rs` guarda la receta por defecto de ese momento en `recipeId` y
   `processRecording` en `controller.ts` la prefiere. Si Rubén cambia la por
   defecto, las notas ya incorporadas siguen con la anterior. Arreglo: `recipeId`
   solo se guarda cuando se elige una receta al añadir o al grabar; sin ella va
   `null` y la por defecto se resuelve al procesar cada nota.
2. **Reprocesar una nota importada de Swift la transcribe entera otra vez.**
   `migration.rs` guarda los criterios de las versiones importadas sin la huella
   del audio ni el modelo y con el nombre de motor de Swift, y el registro
   importado no tiene `audioHash`. Arreglo: calcular `audioHash` de la copia al
   importar y traducir los criterios a los de Tauri (resolutor `local-stt`, el
   modelo de Whisper de Swift, idioma, diarizar y hablantes), para que
   `criteriaKey` de `controller.ts` coincida.
3. **«Resumir» a mano usa siempre Apple Intelligence.** `summarizeRecording` en
   `controller.ts` elige el LLM local si no le pasan otro. En Swift usa el LLM,
   el prompt y el idioma de los valores de «Por defecto» (`AppRuntime.swift`,
   `digester` con `formReading()`). Arreglo: leer esos valores de la receta por
   defecto.
4. **Borrar de la biblioteca no borra las transcripciones.** «Borrar grabación
   y transcripciones» deja el registro con `status: discarded` y todas sus
   versiones. Arreglo: el registro descartado queda como lápida, solo con lo
   necesario para que la vigilancia no lo vuelva a incorporar (`id`, `source`,
   `sourceKey`, `legacyKey`, `status`); fuera versiones, resúmenes, datos y
   copia de audio. Las publicaciones se quedan donde están (Swift tampoco las
   retira).
5. Importar también, como lápidas, las grabaciones que el ledger de Swift
   (`~/.local/state/escriba/ledger.db`, tabla `transcriptions`, `status =
   'discarded'`) tiene descartadas y que ya no están en su biblioteca. En la
   biblioteca de Rubén ya están 32 de las 33, así que es protección para
   instalaciones nuevas. Copia la base a un temporal antes de abrirla.

## 8. Puerta 4: el código a las reglas de la casa

- **Runtime de recetas y conectores en Bun**, no Deno (Rubén). Bun no tiene
  permisos propios: cada proceso de receta corre con un perfil de sandbox de
  macOS (`sandbox-exec`) sin red ni disco y solo sale por las capacidades de
  Escriba. Los tests de aislamiento (`tests/runtime/worker.test.ts` y
  `sidecar.test.ts`) tienen que seguir pasando con Bun. Fuera la selección de
  Deno de `scripts/build-tauri.sh`.
- Rust: structs de serde para grabación, versión, trabajo y ajustes en lugar de
  `serde_json::Value`; errores tipados con «reintentable» como variante en vez de
  buscar `BACKEND_UNAVAILABLE:` en el texto; `store.rs` partido por entidad; sin
  `unwrap` fuera de los tests.
- Quitar los comandos de Rust que solo usaba la interfaz borrada de Codex (por
  ejemplo `notification_permission` y los ajustes `theme`, `language` y
  `autoProcess` como opciones de usuario), después de comprobar con `grep` que
  nada los llama.

## 9. Puertas 5 y 6: tamaño, empaquetado y documentación

- Perfil de release con `strip`, `lto` y `codegen-units = 1`, midiendo tamaño y
  memoria antes y después. La app ocupaba 2,5-3 GB de memoria con la biblioteca
  de Rubén antes de aligerar el transporte; mídela otra vez tras cinco minutos.
- Notarizar una vez con los binarios externos.
- `CLAUDE.md` con una sección por app; decidir con Rubén si vuelve la sonda WASI
  al CI o se retira la frase «El núcleo viaja»; cuando pasen las cinco puertas,
  un ADR que declare la sustitución.

## 10. Lo que no se reabre

Todo lo que dice «Decisiones cerradas» en `CLAUDE.md`, más lo decidido el
2026-10-09: interfaz igual que Swift, fuera búsqueda, filtros y velocidad, Bun
con sandbox, configuración de conectores en la app, React sin librerías de
componentes y controles nativos de Tauri, y las funciones que Codex añadió y
que Rubén dejó fuera (lista en `docs/paridad-swift-tauri.md`).
