# Escriba en Linux

Encargo de Rubén del 2026-10-13. Especificación funcional; no describe la
implementación. La decisión técnica (host nativo en Rust, Swift al mínimo) está
en `docs/adr/0010-linux-host-nativo-en-rust.md`.

## 1. Resumen

Escriba solo existe para macOS. Esta iniciativa lleva la misma aplicación a
Linux: quien se la baje de GitHub en un equipo Linux debe poder señalar
carpetas de grabaciones o grabar, transcribir en local sin cuenta, detectar
hablantes, procesar con recetas y publicar con sus conectores, con el mismo
modelo mental que en el Mac.

La regla general es la **paridad**: lo que las demás especificaciones de
`specs/escriba/` dicen del Mac vale en Linux, salvo las diferencias que lista
la §6.2. La iniciativa incluye además pasar al código común lo que en el Mac
no necesita APIs de Apple, sin cambios visibles para quien usa el Mac (§6.4).

Fuera de alcance: Windows, traer a Linux una biblioteca creada en el Mac y
funciones nuevas que no existan en el Mac.

## 2. Actores

- **La persona usuaria**: cualquiera que se baja Escriba en Linux y la
  configura con sus propias carpetas, modelos, resolutores y cuentas.
- **El escritorio Linux**: muestra la bandeja, las notificaciones y el diálogo
  de permisos de micrófono, y arranca la app al iniciar sesión si se pide.
- **La herramienta de sincronización** que elija la persona (Syncthing,
  Nextcloud, Dropbox u otra), que deja los audios del móvil en una carpeta.
- **Servicios remotos** compatibles con la API de OpenAI, para transcribir o
  resumir, y **proveedores** de publicación (Notion, OKF).

## 3. Objetivos

- Instalar Escriba desde GitHub Releases y abrirla sin instalar nada más.
- Que lo que caiga en una carpeta vigilada se procese solo con la receta por
  defecto, como en el Mac.
- Transcribir en local, sin cuenta en ningún sitio, con el equipo que se tenga.
- Grabar desde la propia app.
- Ejecutar recetas propias con las mismas garantías de aislamiento que en el
  Mac.
- Que quien usa el Mac no note nada al pasar capacidades al código común.

## 4. Puntos de entrada

- Paquetes `.deb` (Debian, Ubuntu) y `.rpm` (Fedora, openSUSE) en GitHub
  Releases.
- Ventana principal con las mismas secciones: Biblioteca, Personas, Trabajos,
  Conectores, STT, LLMs, Recetas, Registro y Ajustes.
- Carpetas vigiladas, configuradas en Ajustes.
- Añadir un audio a mano, eligiendo receta.
- Panel de grabación, desde la ventana, la bandeja (si el escritorio la
  muestra) o el atajo de nueva grabación (Ctrl+N).
- Bandeja del sistema, notificaciones del escritorio e inicio con la sesión.
- Abrir el proyecto de recetas en VS Code.

## 5. Recorridos

**R1. Primer arranque.** La persona instala y abre Escriba → la biblioteca
está vacía → en STT aparece el Whisper local sin modelo → lo descarga de forma
explícita y ve el progreso → al terminar queda disponible. Si no descarga
ningún modelo, lo que entra espera como «no disponible» (regla de recetas
§6.6) y la nota lo dice.

**R2. Vigilar una carpeta.** En Ajustes añade una carpeta → Escriba la recorre
y la vigila → cada audio nuevo entra en la biblioteca y lo procesa la receta
por defecto. *Alternativa:* si la carpeta no se puede leer, Escriba lo muestra
con la ruta y el motivo y lo vuelve a intentar periódicamente; no la trata
como vacía ni ofrece «Autorizar…» ni «Acceso total al disco», que son del Mac.

**R3. Grabar.** Abre el panel de grabación → el escritorio pide permiso de
micrófono si hace falta → graba, pausa, reanuda y para → la grabación entra
en la biblioteca como Opus (`.ogg`) con la receta elegida. *Error:* sin
micrófono o sin permiso,
el panel lo dice y no crea ninguna grabación.

**R4. Transcribir y detectar hablantes.** Igual que en el Mac: la receta pide
transcribir con el motor local o con un resolutor remoto; la diarización solo
se hace si se pide. El motor local usa la gráfica si el equipo tiene una
compatible y, si no, el procesador.

**R5. Resumir y preguntar.** Escriba no trae LLM en Linux: resumir y preguntar
usan un resolutor configurado, sea un servicio remoto o un servidor local
compatible que instale la persona (Ollama, LM Studio). Si la receta no tiene
LLM elegido, o el elegido no responde, ese paso falla de forma visible y la
transcripción se conserva; no se recurre a otro (Rubén, 2026-10-13).

**R6. Personas.** Igual que en el Mac: registrar una voz con 30 segundos de
habla desde micrófono o archivo, y reconocimiento al transcribir.

**R7. Recetas propias.** Igual que en el Mac: proyecto en una carpeta elegida,
construir y ejecutar, con las recetas aisladas. *Alternativa:* si el equipo no
permite aislarlas, todas las recetas (la de por defecto incluida) se ejecutan
igualmente sin aislar y Escriba muestra un aviso permanente (Rubén,
2026-10-13).

## 6. Reglas

### 6.1 Paridad

Todo lo especificado para el Mac en `specs/escriba/` se aplica en Linux:
recetas y ejecuciones, trabajos, filtros de biblioteca, visualización y
edición, conocimiento, conectores, versiones, lápidas y publicaciones. Una
diferencia que no esté en §6.2 es un fallo.

### 6.2 Diferencias en Linux

- **Sin Notas de Voz ni iCloud.** No se siembra la carpeta de Notas de Voz ni
  se ofrece su estilo de carpeta. Las grabaciones del móvil llegan por la
  sincronización que elija la persona. Los ficheros de solo marcador (sin
  descargar) de esas herramientas no se descargan: se ignoran hasta que
  aparece el audio.
- **Sin autorización de carpetas.** No hay «Autorizar…» ni «Acceso total al
  disco»: si los permisos del sistema impiden leer, se avisa (R2).
- **Sin LLM incluido.** No aparece Apple Intelligence ni otro motor propio: la
  lista de LLMs empieza vacía.
- **El Whisper local se llama «Whisper · en este equipo»** y tiene sus propios
  modelos, distintos de los del Mac. El de serie es large-v3-turbo.
- **Atajos con Ctrl** donde el Mac usa ⌘.
- **Lo grabado desde Escriba se guarda en Opus (`.ogg`)**, no en m4a. Lo que
  entra por carpetas o al añadir un audio admite los mismos formatos que el
  Mac, m4a incluido: m4a, mp3, wav, aac, flac, ogg/oga/opus, mp4, aiff/aif y
  caf (Rubén, 2026-10-13).

### 6.3 Datos y credenciales

- La biblioteca, la configuración y los modelos viven en las carpetas de
  datos del usuario del sistema; desinstalar no los borra.
- Las credenciales se guardan en ficheros privados del usuario, como en el
  Mac. No se usa el llavero del escritorio.
- Actualizar a una versión nueva conserva biblioteca, configuración y modelos.

### 6.4 El Mac durante la iniciativa

- Pasar al código común la lectura de duración, el estado de los ficheros, la
  descarga de iCloud y la grabación no cambia nada visible: mismo formato de
  grabación, mismos permisos y mismas notas. El permiso de micrófono ya
  concedido se conserva.
- El Mac conserva sus motores nativos de transcripción, hablantes y LLM; Linux
  usa los que mejor encajan con Linux (Rubén, 2026-10-13).

## 7. Conceptos

- **Motor local de transcripción**: el que transcribe en el propio equipo sin
  cuenta. En Linux tiene sus propios modelos, que se descargan explícitamente.
- **Huella de voz**: identifica a una persona en las grabaciones y se queda en
  el equipo, como en el Mac.
- **Carpeta vigilada**: carpeta cuyo audio entra solo en la biblioteca. En
  Linux no tiene autorización guardada: o se puede leer o se avisa.
- **Aislamiento de recetas**: garantía de que el código de una receta no ve
  tokens, rutas de audio ni huellas, y solo actúa a través de Escriba.

## 8. Interfaz

La misma ventana y las mismas secciones que en el Mac, con estos cambios:

- **Ajustes → Carpetas**: sin «Autorizar…» ni «Acceso total al disco»; el pie
  no menciona macOS.
- **STT**: «Whisper · en este equipo», con su lista de modelos.
- **LLMs**: empieza vacía; se añaden resolutores como en el Mac.
- **Bandeja**: si el escritorio no muestra iconos de bandeja, grabar y ver el
  estado siguen siendo posibles desde la ventana principal.
- **Panel de grabación**: flotante como en el Mac donde el escritorio lo
  permite (ver §9).
- **Avisos de permisos**: sin enlaces a Ajustes del Sistema de macOS; explican
  qué permiso falta.
- **Aviso de recetas sin aislar**: visible de forma permanente mientras el
  equipo no permita aislarlas; explica qué falta.

## 9. Restricciones

- Windows queda fuera.
- Solo hay paquetes `.deb` y `.rpm`, para x86_64 y arm64. Se soportan Ubuntu
  LTS 24.04 y 26.04, Debian 13 y las dos últimas Fedora; en otras
  distribuciones (openSUSE, Arch…) puede funcionar, pero no se prueba.
- Sin Notas de Voz ni iCloud, y sin LLM incluido.
- En Wayland el sistema no deja a las apps elegir dónde va una ventana ni
  mantenerla siempre encima: el panel de grabación puede no quedar flotando
  donde en el Mac.
- Algunos escritorios (GNOME sin extensión) no muestran iconos de bandeja.
- Sin gráfica compatible, transcribir es bastante más lento que en un Mac con
  Neural Engine.
- En un equipo sin aislamiento, las recetas no tienen la protección del Mac:
  su código puede leer ficheros del usuario y salir a la red.

## 10. Preguntas y supuestos

### Preguntas, decididas el 2026-10-13

1. **LLM local en Linux. Decidido (Rubén, 2026-10-13): solo resolutores.**
   Escriba no incluye motor; lo local es un servidor compatible que instala la
   persona.
2. **Formato del paquete. Decidido (Rubén, 2026-10-13): `.deb` y `.rpm`.** Sin
   AppImage ni Flatpak.
3. **Equipo sin aislamiento de recetas. Decidido (Rubén, 2026-10-13): se
   ejecuta todo con un aviso permanente.** Es lo más simple; en ese equipo el
   código de una receta podría leer ficheros o salir a la red por su cuenta.
4. **Formato de las grabaciones hechas en Linux. Decidido (Rubén,
   2026-10-13): Opus (`.ogg`) al grabar; m4a y el resto se siguen aceptando al
   importar o vigilar.**
5. **Modelo de Whisper por defecto en Linux. Decidido (Rubén, 2026-10-13):
   large-v3-turbo.** Los demás modelos siguen disponibles para descargar.
6. **Distribuciones y arquitecturas. Decidido (Rubén, 2026-10-13):** Ubuntu
   LTS 24.04 y 26.04, Debian 13 y las dos últimas Fedora, en x86_64 y arm64.
   Cada versión se prueba en ellas antes de publicarse.
7. **Traer una biblioteca del Mac. Decidido (Rubén, 2026-10-13): no.** En
   Linux se empieza con una biblioteca nueva; se puede reconsiderar si alguien
   lo pide.
8. **Motor común en el Mac. Decidido (Rubén, 2026-10-13): no.** Cada sistema
   usa su motor nativo.

### Comprobación pendiente

- Que una distribución soportada recién instalada reproduzca m4a en la app. Si
  no, el paquete debe traer lo necesario.

### Supuestos

- La identidad de la app y sus datos sigue la del Mac; en Linux se crea una
  biblioteca nueva.
- El nombre «Whisper · en este equipo» y los atajos con Ctrl son propuesta de
  esta especificación, no decisión tomada.
- Las actualizaciones son manuales, descargando la versión nueva, como hoy en
  el Mac.
- Abrir en VS Code usa el VS Code que tenga instalado la persona; si no lo
  tiene, se avisa.
