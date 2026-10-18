# Changelog

## [0.3.1](https://github.com/Zetesis-Labs/escriba/compare/v0.3.0...v0.3.1) (2026-10-18)


### Bug Fixes

* **macos:** el empaquetado funciona con el bash 3.2 de macOS ([391fccb](https://github.com/Zetesis-Labs/escriba/commit/391fccb828f339ea8602c189dbb358314e6a9249))
* **tests:** la ayuda de errores de storage solo existe donde se usa, en Windows ([5f965a3](https://github.com/Zetesis-Labs/escriba/commit/5f965a340f9c56342e90a24d4ee69db5bfc3c85c))
* **ui:** quitar el hueco lateral fuera de macOS y preparar 0.3.1 ([#42](https://github.com/Zetesis-Labs/escriba/issues/42)) ([10bab44](https://github.com/Zetesis-Labs/escriba/commit/10bab44b86119b0ac03edc90bb7de3256d17bf01))

## [0.3.0](https://github.com/Zetesis-Labs/escriba/compare/v0.2.0...v0.3.0) (2026-10-17)


### Features

* **biblioteca:** «Resumir» de la nota lanza la receta Resumir sobre la versión abierta ([7e5e148](https://github.com/Zetesis-Labs/escriba/commit/7e5e14863a7bad8eece4b064ee9ee84ebb0eaa7f))
* **biblioteca:** borrar una versión o quedarse solo con una desde el menú de versiones ([ff21933](https://github.com/Zetesis-Labs/escriba/commit/ff21933e53f3239828c0a056ddb95f0ce4ac8686))
* **biblioteca:** combinar grabaciones desde la selección múltiple ([9d7ea4c](https://github.com/Zetesis-Labs/escriba/commit/9d7ea4c77c44b9f26908270bc7ab3bf7fccb03a8))
* **biblioteca:** una corrección conserva los criterios, el resumen y los datos de su versión, y las antiguas toman los de la anterior ([33d9472](https://github.com/Zetesis-Labs/escriba/commit/33d9472ac9f647d232a381f497355e2bcb70e468))
* **conocimiento:** una versión derivada hereda los vínculos de su origen y los de una versión que ya no existe se retiran ([67bf1a6](https://github.com/Zetesis-Labs/escriba/commit/67bf1a63336695570bed0a6c5e10e98949151a1b))
* **recetas:** cada receta declara si parte de un audio o de una nota y solo se ofrece donde puede empezar ([e12cb4e](https://github.com/Zetesis-Labs/escriba/commit/e12cb4e72a59def7c7e0aa8d5dc5d140b414ebb1))
* **recetas:** la receta trabaja sobre una copia de la versión abierta y guarda una versión derivada ([e224c04](https://github.com/Zetesis-Labs/escriba/commit/e224c04a6c6732c83d4d71fb475050e69faeb3a8))
* **recetas:** reprocesar a mano vuelve a transcribir una vez y guardar sin cambios no toca la vigente ([9a8dfd6](https://github.com/Zetesis-Labs/escriba/commit/9a8dfd6553335ba8808122fe27d9ff09706a473a))
* **recetas:** Transcribir, Resumir y Publicar de serie y «Por defecto» compuesta con ellas ([8265c86](https://github.com/Zetesis-Labs/escriba/commit/8265c86c0b0f13ec13c39edb211dc83238897ffe))
* **windows:** adapta Escriba con Whisper y diarización nativos ([aeec24a](https://github.com/Zetesis-Labs/escriba/commit/aeec24a766d8bea08705377b6642c2f34d6c3d3a))


### Bug Fixes

* **audio:** conservar el error al rechazar archivos no normales ([cc6aa91](https://github.com/Zetesis-Labs/escriba/commit/cc6aa9136484cec61b719aad7ed78b4f95ee81c2))
* **biblioteca:** el clic derecho no deshace la selección múltiple y Rust deja pasar combineAudio ([81c1ad1](https://github.com/Zetesis-Labs/escriba/commit/81c1ad1c2a8dbe5a032b199fe0806829ae5946f9))
* **ci:** corregir construcción aislada y fallos de pruebas ([29fa024](https://github.com/Zetesis-Labs/escriba/commit/29fa024cdeec38b889df5012a37cb55371283ec8))
* **ci:** corregir rutas de Windows y portabilidad de la inferencia ([96812fb](https://github.com/Zetesis-Labs/escriba/commit/96812fb9d9cbf5955b6e39b258ee3e6bd356921c))
* **ci:** descartar la extracción incompleta de sherpa ([32f1edd](https://github.com/Zetesis-Labs/escriba/commit/32f1edd40f7b817e40a9f926fe61159cd809c73c))
* **ci:** instalar la versión fijada de Bun en Windows ([f92d375](https://github.com/Zetesis-Labs/escriba/commit/f92d375878372dc297f35672a0d4b5f11449e14a))
* **ci:** restaurar las bibliotecas de sherpa tras recuperar la caché ([35654c8](https://github.com/Zetesis-Labs/escriba/commit/35654c8ddf675e8482e27bebc6b9fb96800a5551))
* **recetas:** la primera versión de una nota es vigente y la misma nota es el mismo objeto en la receta ([1e092f2](https://github.com/Zetesis-Labs/escriba/commit/1e092f26933bd0ded2f433c4d5f9babae6fccacb))
* **recetas:** una ejecución que no transcribe no cambia el estado de la nota y relanzar repite su receta ([e057be1](https://github.com/Zetesis-Labs/escriba/commit/e057be1a9d7ed0444132ca84d4e62566f3c1aef9))
* **tests:** en macOS esperar a que RocksDB cierre su LOCK antes de borrar la base ([f49878a](https://github.com/Zetesis-Labs/escriba/commit/f49878a64b39ab99ec617f3847b1fc06a6e77d86))
* **windows:** interpretar dependencias de Bun entre unidades ([8746e15](https://github.com/Zetesis-Labs/escriba/commit/8746e15d4b1711113df737b191cc502ff8dad2e0))
* **windows:** resolver rutas aisladas sin consultar el gestor de volúmenes ([b884a5e](https://github.com/Zetesis-Labs/escriba/commit/b884a5e919f764f1d663cf43e043d3abfc66aeab))

## [0.2.0](https://github.com/Zetesis-Labs/escriba/compare/v0.1.0...v0.2.0) (2026-10-15)


### Features

* añadir, descargar, borrar y quitar modelos de Whisper desde STT ([fab80c0](https://github.com/Zetesis-Labs/escriba/commit/fab80c05d5bd19f407bfefe20142f591aca065e9))
* cada Whisper local transcribe con su modelo y lo deja en la huella ([92474d1](https://github.com/Zetesis-Labs/escriba/commit/92474d19b2280d9d41f95d2f12bce838cea53a31))
* **linux:** abrir en VS Code con su dirección vscode:// ([131c538](https://github.com/Zetesis-Labs/escriba/commit/131c538d4088148431ea652fe0348366d092e48d))
* **linux:** Ajustes sin Notas de Voz, autorizar ni acceso total al disco ([d3f503f](https://github.com/Zetesis-Labs/escriba/commit/d3f503f4e23af7b755e04f66bdfd9aa0bb26e2d4))
* **linux:** aviso permanente en Recetas mientras el equipo no las aísle ([fc1c748](https://github.com/Zetesis-Labs/escriba/commit/fc1c74891e5403f3a5742766b548c8fe014c0936))
* **linux:** barra de cabecera al estilo de GNOME en lugar de la del Mac ([8745975](https://github.com/Zetesis-Labs/escriba/commit/87459758388c8b36901fcc6d8ee57c75fe715869))
* **linux:** carpetas vigiladas sin bookmark y sin Notas de Voz ([ed31b2c](https://github.com/Zetesis-Labs/escriba/commit/ed31b2c3fe8b5cea99dbdbb07fec34cf13038e93))
* **linux:** catálogo de modelos de Whisper y borrado por modelo en el host ([8721fb3](https://github.com/Zetesis-Labs/escriba/commit/8721fb37d22686ff7198965359c0cd27467fdd4d))
* **linux:** dentro de Flatpak cada carpeta se autoriza por el portal, como en el Mac ([5509c3d](https://github.com/Zetesis-Labs/escriba/commit/5509c3d08a518a41fc05e2320fdd64bee4c97960))
* **linux:** detectar hablantes con sherpa-onnx en el host nativo ([01c8f0b](https://github.com/Zetesis-Labs/escriba/commit/01c8f0b4e207ef0d6b103ce0c5a25c35ae50bf60))
* **linux:** ejecutar recetas y herramientas sin aislar mientras Linux no lo permita ([823cb3c](https://github.com/Zetesis-Labs/escriba/commit/823cb3ca26d84109a0f0fef479b78e0dd8e7e353))
* **linux:** el panel de grabación va dentro de la ventana ([4c9dc71](https://github.com/Zetesis-Labs/escriba/commit/4c9dc7162ed4b74030cbb7033a6b627467a89454))
* **linux:** elegir y restaurar carpetas sin bookmarks ([bbc29e5](https://github.com/Zetesis-Labs/escriba/commit/bbc29e5f2743b99c536fd852660fb24897a32aa5))
* **linux:** en Flatpak Ajustes ofrece volver a autorizar una carpeta ([302b9d2](https://github.com/Zetesis-Labs/escriba/commit/302b9d2c65a32f900771f11a6e07afdf4c97a760))
* **linux:** escriba-sandbox aísla con Landlock y seccomp los perfiles del Mac ([c166731](https://github.com/Zetesis-Labs/escriba/commit/c1667312784d3d7f1a1e9c6863cb6c9b59030872))
* **linux:** estado de archivo sin SF_DATALESS ([d6900c1](https://github.com/Zetesis-Labs/escriba/commit/d6900c1dcb82d4e8d1605112743aac30416131f5))
* **linux:** grabar en Opus desde el host nativo de Rust ([1c9efdc](https://github.com/Zetesis-Labs/escriba/commit/1c9efdcbbce1e5c17a6695d69c4bfa3261512c00))
* **linux:** host nativo mínimo en Rust ([1da4d3c](https://github.com/Zetesis-Labs/escriba/commit/1da4d3cbfaf888db113f13ebc5e7e8f61225c8ae))
* **linux:** iconos de la bandeja dibujados sin SF Symbols ([4656798](https://github.com/Zetesis-Labs/escriba/commit/4656798bf081c28deb6a290224d222d77a6efd4a))
* **linux:** inicio con la sesión por el portal Background dentro de Flatpak ([7701fda](https://github.com/Zetesis-Labs/escriba/commit/7701fda7cc64f3bfbfa276d7f53163aa02b8b059))
* **linux:** large-v3-turbo como Whisper de serie ([559b514](https://github.com/Zetesis-Labs/escriba/commit/559b5141c23b48e22fb8e8f3fb5899dd69ef18ab))
* **linux:** las grabaciones se guardan como .ogg ([9398936](https://github.com/Zetesis-Labs/escriba/commit/9398936202c173bed2d7710ef353830595532af5))
* **linux:** memoria e identidad de los workers desde /proc ([1bad9c3](https://github.com/Zetesis-Labs/escriba/commit/1bad9c361b21abe201b02172f0f47ac90a09e8ab))
* **linux:** módulo de plataforma para abrir, mostrar, modelos y permisos ([b0b678c](https://github.com/Zetesis-Labs/escriba/commit/b0b678c21c1aeda941f5df26c5a86511f22c038f))
* **linux:** notificaciones del escritorio ([7737161](https://github.com/Zetesis-Labs/escriba/commit/773716199e18341773b271677685df4d6ca017c2))
* **linux:** panel de grabación flotante con fondo propio ([41e03fd](https://github.com/Zetesis-Labs/escriba/commit/41e03fd3231f7415e9fdc6bc8dc03bc7efb0bd1a))
* **linux:** recetas y herramientas del proyecto aisladas con escriba-sandbox ([dd6486d](https://github.com/Zetesis-Labs/escriba/commit/dd6486d78dfc4226fe7027a6d1bc7f631aae1d46))
* **linux:** resumir sin LLM elegido falla diciendo qué falta ([ca5f131](https://github.com/Zetesis-Labs/escriba/commit/ca5f131f02d322c205ba674db4d12221edf35f50))
* **linux:** sin barra de menús dentro de la ventana ([3381aec](https://github.com/Zetesis-Labs/escriba/commit/3381aec5911c928428cf9a6d9e8477ab20cbb7f0))
* **linux:** sin gráfica, WebKitGTK pinta por software ([dfa1991](https://github.com/Zetesis-Labs/escriba/commit/dfa199185d307e4572698fc83bbb4cf50f240a98))
* **linux:** textos de la interfaz según el sistema ([1270184](https://github.com/Zetesis-Labs/escriba/commit/1270184894c007b150f82b3c9d8ac09f2a74cd27))
* **linux:** triple de desarrollo según el objetivo de compilación ([4f6d4d5](https://github.com/Zetesis-Labs/escriba/commit/4f6d4d547499077943efbdd1fe9f7dfdb309ee17))
* **linux:** valores de serie sin LLM incluido y plataforma para la interfaz ([046ed33](https://github.com/Zetesis-Labs/escriba/commit/046ed332516568e333e130534587921299dcc430))
* **linux:** ventana integrada como en macOS ([d3ae32d](https://github.com/Zetesis-Labs/escriba/commit/d3ae32d7e1c284657959c218b0dd55877c1a93ba))
* **linux:** Whisper local con whisper.cpp en el host nativo ([7b27d68](https://github.com/Zetesis-Labs/escriba/commit/7b27d68ade66ed2847783b2facfb9dba287bb666))
* los modelos de Whisper añadidos son resolutores locales ([bdcd269](https://github.com/Zetesis-Labs/escriba/commit/bdcd269396387a1bc0012b5ff239a16cd0597aa5))
* **personas:** cada modelo de huellas reconoce con su propio umbral ([b256410](https://github.com/Zetesis-Labs/escriba/commit/b25641049af84c601eb48047df521098cab1638d))
* **stt:** el Whisper de serie se puede quitar y la receta sin STT usa el primer Whisper local ([3f9f429](https://github.com/Zetesis-Labs/escriba/commit/3f9f4291b625eb50b2fea07f9ba1a31444419aba))
* whisper_model trabaja por modelo y la interfaz puede pedir el catálogo ([1cd0313](https://github.com/Zetesis-Labs/escriba/commit/1cd0313bcb96f83ac4038c1e9642ab6e35fe2c27))


### Bug Fixes

* **biblioteca:** el borrado pendiente distingue un archivo nuevo aunque reutilice el inodo ([66604ff](https://github.com/Zetesis-Labs/escriba/commit/66604ffe3b5000dd64a99ce9449770cf97ceda59))
* **biblioteca:** leer una nota y sus versiones en una sola transacción ([24d842f](https://github.com/Zetesis-Labs/escriba/commit/24d842f43b32e34b1ef2d8afb7a8390c20464273))
* Descargar dice el tamaño de cada modelo de Whisper ([19ab17a](https://github.com/Zetesis-Labs/escriba/commit/19ab17a00eb9b2c516fe6f2c8e4209671482caf8))
* **linux:** clippy en arm64, donde la lista de llamadas bloqueadas no crece ([c60ddb1](https://github.com/Zetesis-Labs/escriba/commit/c60ddb199f555b2868e32fc9814c12565b1f18c4))
* **linux:** el Flatpak arranca: sin strip y con la bandeja de AppIndicator ([7c8de22](https://github.com/Zetesis-Labs/escriba/commit/7c8de224c1f155907715ef7c510149025cbc4dc7))
* **linux:** el Flatpak desactiva el renderizado dmabuf de WebKitGTK ([f329553](https://github.com/Zetesis-Labs/escriba/commit/f3295535fd28ab22cf67422f29ded257dd69440f))
* **linux:** el Flatpak repinta la ventana entera sin la composición acelerada de WebKit ([e6d1d71](https://github.com/Zetesis-Labs/escriba/commit/e6d1d7170109a2f5e9665a793014d5ae1c47e877))
* **linux:** el panel de grabación conserva la altura de la píldora ([c63929f](https://github.com/Zetesis-Labs/escriba/commit/c63929f6dfe5e72ceb872f87b2e526c3f93c9e54))
* **linux:** el panel de grabación se centra sobre el contenido ([51f61c0](https://github.com/Zetesis-Labs/escriba/commit/51f61c07c622acaac48a079160ac7554fa5f241f))
* **linux:** esperar en las pruebas a que RocksDB suelte de verdad su bloqueo ([f51f958](https://github.com/Zetesis-Labs/escriba/commit/f51f958011726869668f492aaed4bf277938672e))
* **linux:** inicio con la sesión sin el lanzador de macOS ([76326fd](https://github.com/Zetesis-Labs/escriba/commit/76326fd4594bc2fabed6c9603cf6665c151ba6d5))
* **linux:** la receta por defecto funciona sin LLMs ([6c4b06c](https://github.com/Zetesis-Labs/escriba/commit/6c4b06cb5853fe46f788142abe8cd819aed4122d))
* **linux:** los iconos de la bandeja se ven desde Flatpak ([b713f40](https://github.com/Zetesis-Labs/escriba/commit/b713f4073dbdf5a732085b8d054a442c21b90918))
* **linux:** sin el hueco de los botones del Mac sobre la barra lateral ([5a53756](https://github.com/Zetesis-Labs/escriba/commit/5a537561687c85bfa483f19d2d067080d1dcbc77))
* **tests:** cerrar del todo cada base RocksDB al acabar su test ([dfbe6cc](https://github.com/Zetesis-Labs/escriba/commit/dfbe6ccc4494420e3afd68fd12f568ede129789a))


### Reverts

* el CI vuelve a correr solo en main y en las pull requests ([10b5acf](https://github.com/Zetesis-Labs/escriba/commit/10b5acf2b1b3b4cb239b3b99eeae8f8dc69dccfb))
