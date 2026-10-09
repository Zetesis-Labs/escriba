# Paridad de la interfaz con la app Swift

Puerta 2 del ADR-0004. Decisión de Rubén del 2026-10-09: la interfaz que hizo
Codex se tira y se rehace **igual que la de la app SwiftUI**, pantalla por
pantalla. El motor se queda: cola y vigilancia en Rust, runtime de recetas,
host nativo y conectores.

La referencia es la app SwiftUI de `feat/personas` (2e8614b), que incluye
Personas y el editor de plantillas. Las rutas de Swift son relativas a
`Sources/EscribaMenuBar/` salvo que se diga otra cosa.

Límite asumido: dentro de una WebView «igual» significa las mismas secciones,
textos, flujos, paneles, menús y atajos. Los controles nativos y el cristal de
macOS 26 se imitan, no se reproducen al píxel.

## Lo que añadió Codex

Se queda, porque Tauri lo necesita:

- [x] Autorizar cada carpeta vigilada sin pedir acceso total al disco, reautorizarla y el acceso total como alternativa.
- [x] Importar la biblioteca de Swift, automática la primera vez y manual después.
- [x] La cola duradera con reintentos, sin interfaz propia.

Se queda mientras Rubén no la vete:

- [x] Exportar a TXT, Markdown, SRT y JSON.
- [x] Cancelar una nota que se está procesando.

Ampliación pedida por Rubén el 2026-10-09:

- [ ] Registrar una voz eligiendo un archivo de audio, además de grabarla con el micrófono. Exige los mismos 30 s de habla y conserva el archivo original.

Fuera:

- [ ] Buscar y filtrar en la biblioteca. **Rubén la diseñará más adelante; no se implementa de paso.**
- [ ] Velocidad de reproducción.
- [ ] Editar el texto o el hablante de cada segmento, «Guardar corrección» y el cuadro de texto sin segmentos.
- [ ] Editar el título, el resumen y los datos en JSON.
- [ ] Republicar en los destinos al editar.
- [ ] Pausar y reanudar la grabación.
- [ ] Tema claro, oscuro o del sistema: se sigue al sistema, como Swift.
- [ ] Idioma de transcripción y modelo Whisper en Ajustes: el idioma es de la receta y Ajustes solo tiene General y Carpetas vigiladas.
- [ ] «Procesar automáticamente». Solo queda la pausa interna mientras se importa la biblioteca de Swift.
- [ ] Receta guardada en cada grabación («Receta para el próximo proceso»): la receta se elige al añadir, al grabar o al reprocesar, solo esa vez.
- [ ] Botón «Diarizar» suelto: se pide en la hoja de reprocesar.
- [ ] Descartar y restaurar como paso intermedio: Swift borra de la biblioteca y ya.
- [ ] Interruptor «activo» en los resolutores.
- [ ] «Validar» y «Descubrir» que vuelcan JSON, y elegir la grabación de la vista previa.
- [ ] Ver la fuente de una receta de código y el selector «Basada en».
- [ ] «Comprobar notificaciones».
- [ ] «Trabajos y reintentos», vaciar el registro y los filtros por nivel y por grabación.
- [ ] Estado de trabajos en la barra lateral y el botón «Actualizar».
- [ ] Ruta de almacenamiento visible en Ajustes.

El modo `?demo=1` se queda solo como herramienta de desarrollo para capturas;
la app instalada nunca lo muestra.

## Lo que hay que construir, por sección

Cada casilla se marca cuando funciona en la app instalada y Rubén lo ha visto.

### Ventana, menús y barra de menús

- [ ] Barra lateral con Biblioteca, Personas, Conectores, STT, LLMs, Recetas, Registro y Ajustes, en ese orden (`MainWindow.swift`).
- [ ] Ítem de la barra de menús con icono según el estado (vigilando, trabajando, problema) y su texto (`MenuBarApp.swift`, `EscribaModel/WatcherStatus.swift`).
- [ ] Su menú: estado, «N en la biblioteca», «Grabar nota» o «Detener y transcribir (reloj)» y «Descartar la grabación», «Abrir biblioteca», «Buscar grabaciones ahora», «Conectores…», «Ajustes…», «Ver registro» y «Salir».
- [ ] ⌘N para «Nueva grabación» y «Detener y transcribir».
- [ ] Salir con una grabación en curso la detiene y la guarda antes de cerrar.
- [ ] Una sola copia de la app: abrir otra lleva a la que ya está abierta.

### Grabación

- [ ] Panel flotante encima de todo, en todos los escritorios, arriba en el centro: punto rojo que late, reloj, «con «receta»» o «Grabando», forma de onda de 48 barras, descartar y detener (`RecordingPanel.swift`).
- [ ] Ítem con reloj en la barra de menús mientras se graba; pulsarlo detiene y transcribe (`RecordingStatusItem.swift`).
- [ ] Descartar borra la grabación en curso sin pasarla a la biblioteca.
- [ ] El Mac no se duerme mientras graba.
- [ ] Sin permiso de micrófono: alerta con «Abrir Ajustes del Sistema», que lleva al panel de Micrófono.

### Biblioteca

- [ ] Barra: «Añadir audio…» con la receta por defecto y, en la flecha, con otra; «Grabar» igual; «Detener» mientras se graba (`LibraryWindow.swift:86-115`).
- [ ] Fila: título, extracto, etiquetas, estado, origen, «en Notion» y aviso si falló una publicación (`LibraryWindow.swift:311-364`).
- [ ] Recuento «N en la biblioteca, M sin transcribir» (`EscribaModel/LibraryText.swift`).
- [ ] Menú contextual de la fila.
- [ ] Vacío: «Arrastra aquí un audio o pulsa Grabar».
- [ ] Arrastrar audios: «Suelta para transcribir», con la validación de Swift.
- [ ] Aviso de 8 s tras añadir: añadidas, rechazadas y fallidas (`EscribaModel/InboxModel.swift`).
- [ ] Bandeja de Escriba para lo añadido y lo grabado.

### Detalle de una grabación

- [ ] Cabecera: fecha larga, origen, duración, número de hablantes, «versión x de y» y etiquetas.
- [ ] Reproductor; el segmento o la palabra que suena se resalta y pulsar el texto salta ahí (`PlayerViews.swift`).
- [ ] Audio ausente: «Solo queda la transcripción: el audio ya no existe».
- [ ] Resumen en línea con «Resumir», «Rehacer», «Resumiendo…» y quitar.
- [ ] Datos como tabla de etiqueta y valor (`NoteDataView.swift`).
- [ ] Tarjeta «Cómo se procesó» con pasos, logs, datos, error y «Copiar» (`TraceCard.swift`).
- [ ] Menú de versiones con la actual marcada.
- [ ] «Reprocesar con una receta…»: hoja con la receta y sus parámetros solo esa vez (`ReprocessSheet.swift`).
- [ ] «Transcribir ahora» y «Reintentar» en pendientes y fallidas.
- [ ] Hablantes: renombrar, fusionar y «No es X», insignia de reconocido y aviso «Renombrado, pero sin aprender su voz».
- [ ] Copiar la transcripción y copiar el JSON de Swift.
- [ ] Publicar: un menú por conector activo; en lo publicado, abrir, mostrar en el Finder, actualizar y borrar, con los textos de Notion y de OKF.
- [ ] Quitar la copia de audio y borrar de la biblioteca, con los avisos de Swift.
- [ ] Los errores de una acción salen en una alerta.

### Personas

- [ ] Lista de personas con sus huellas, renombrar, juntar y olvidar (`PeoplePane.swift`).
- [ ] «Registrar voz» con 30 s de voz como mínimo.
- [ ] Reconocimiento al transcribir; las huellas no salen del Mac ni llegan a recetas, conectores o exportación.

### Conectores

- [ ] Lista de conectores con añadir y quitar, con el aviso de cada tipo.
- [ ] Notion: nombre, «publicar cada transcripción nueva», token, conectar o actualizar bases y elegir base.
- [ ] Notion: valor de cada columna y cuerpo de la página con el editor de pastillas y «/» (`TokenEditor.swift`).
- [ ] OKF: carpeta, mostrarla en el Finder, N documentos con ruta, propiedades, cuerpo y enlaces (`OKFEditor.swift`).
- [ ] «Así queda» en vivo para Notion y OKF.
- [ ] Guardar y descartar cambios.

Decidido por Rubén el 2026-10-09: la configuración de cada destino vive en la
app, como en Swift. El editor la guarda como datos y la librería TypeScript la
interpreta al publicar; los destinos escritos en código en el proyecto siguen
funcionando. Detalle en `docs/pendiente-tauri.md`, apartado 3.

### STT y LLMs

- [ ] Lista con el local fijo arriba; quitar un remoto avisa de que sus recetas pasan al local.
- [ ] Presets de OpenAI, Groq, OpenRouter, LM Studio y Ollama (`ResolversPane.swift`).
- [ ] URL, clave y modelo, «Cargar modelos» y «Probar».
- [ ] Aviso de lo que falta por configurar.
- [ ] Whisper local: estado del modelo, descarga con progreso y borrar del disco (`SettingsView.swift:130-191`).

### Recetas

- [ ] Lista por secciones; nueva, duplicar, usar por defecto y quitar con al menos dos recetas (`RecipesPane.swift`).
- [ ] Guardar una receta de código como receta de formulario.
- [ ] Parámetros que se guardan al editar, «Volver a los valores de serie» y campos que dependen de un interruptor.
- [ ] Proyecto: elegir, cambiar, abrir y la fase de compilación; estado por receta y abrirla en el Finder.
- [ ] «Probar con una nota» y ejecuciones de la receta en 30 días con filtro (`RecipeRunsViews.swift`).

### Registro

- [ ] Pestañas «Ejecuciones» y «Log de la app» (`LogPane.swift`).
- [ ] Ejecuciones con filtros, pasos, logs, datos y «Copiar».
- [ ] Log con filtro, «Solo errores», «Copiar» y «Abrir el fichero».

### Ajustes

- [ ] General: abrir al iniciar sesión y avisar al terminar cada transcripción; los problemas se avisan siempre.
- [ ] Carpetas vigiladas: añadir, quitar y «Añadir Notas de Voz»; una instalación nueva siembra Notas de Voz.

### Notificaciones

- [ ] Los textos de Swift: «Nota transcrita» con el principio del texto, «Fallo al transcribir», motor que no responde, receta no disponible, grabaciones que no se pueden leer, recetas que no arrancan y otra copia abierta (`Notifier.swift`).

## Lo que el motor tiene que arreglar

- Las versiones importadas de Swift guardan sus criterios sin la huella del
  audio ni el modelo y con el nombre de motor de Swift. Nunca coinciden con los
  de Tauri, así que reprocesar una nota antigua la vuelve a transcribir entera.
- La app ocupa 2,5 a 3 GB de memoria con la biblioteca de Rubén.
- El host nativo no da niveles de audio ni sabe descartar una grabación.
