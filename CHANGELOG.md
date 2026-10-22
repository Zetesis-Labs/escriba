# Changelog

## [0.3.1](https://github.com/Zetesis-Labs/escriba/compare/v0.3.0...v0.3.1) (2026-10-18)


### Bug Fixes

* **macos:** packaging works with the bash 3.2 that ships with macOS ([391fccb](https://github.com/Zetesis-Labs/escriba/commit/391fccb828f339ea8602c189dbb358314e6a9249))
* **tests:** the storage error helper only exists where it is used, on Windows ([5f965a3](https://github.com/Zetesis-Labs/escriba/commit/5f965a340f9c56342e90a24d4ee69db5bfc3c85c))
* **ui:** align the sidebar with the panel title ([4aa5c77](https://github.com/Zetesis-Labs/escriba/commit/4aa5c774c6e5b5156868b5a8813ff8b81614dbb3))
* **ui:** remove the side gap outside macOS and prepare 0.3.1 ([#42](https://github.com/Zetesis-Labs/escriba/issues/42)) ([10bab44](https://github.com/Zetesis-Labs/escriba/commit/10bab44b86119b0ac03edc90bb7de3256d17bf01))

## [0.3.0](https://github.com/Zetesis-Labs/escriba/compare/v0.2.0...v0.3.0) (2026-10-17)


### Features

* **library:** the note's "Resumir" (Summarize) runs the Resumir recipe on the open version ([7e5e148](https://github.com/Zetesis-Labs/escriba/commit/7e5e14863a7bad8eece4b064ee9ee84ebb0eaa7f))
* **library:** delete a version, or keep only one, from the versions menu ([ff21933](https://github.com/Zetesis-Labs/escriba/commit/ff21933e53f3239828c0a056ddb95f0ce4ac8686))
* **library:** combine recordings from the multiple selection ([9d7ea4c](https://github.com/Zetesis-Labs/escriba/commit/9d7ea4c77c44b9f26908270bc7ab3bf7fccb03a8))
* **library:** a correction keeps the criteria, summary and data of its version, and older ones take those of the previous version ([33d9472](https://github.com/Zetesis-Labs/escriba/commit/33d9472ac9f647d232a381f497355e2bcb70e468))
* **knowledge:** a derived version inherits the links of its source, and the links of a version that no longer exists are removed ([67bf1a6](https://github.com/Zetesis-Labs/escriba/commit/67bf1a63336695570bed0a6c5e10e98949151a1b))
* **recipes:** each recipe declares whether it starts from audio or from a note, and is only offered where it can start ([e12cb4e](https://github.com/Zetesis-Labs/escriba/commit/e12cb4e72a59def7c7e0aa8d5dc5d140b414ebb1))
* **recipes:** the recipe works on a copy of the open version and saves a derived version ([e224c04](https://github.com/Zetesis-Labs/escriba/commit/e224c04a6c6732c83d4d71fb475050e69faeb3a8))
* **recipes:** reprocessing by hand transcribes again once, and saving without changes leaves the current version alone ([9a8dfd6](https://github.com/Zetesis-Labs/escriba/commit/9a8dfd6553335ba8808122fe27d9ff09706a473a))
* **recipes:** built-in Transcribir, Resumir and Publicar, with "Por defecto" composed of them ([8265c86](https://github.com/Zetesis-Labs/escriba/commit/8265c86c0b0f13ec13c39edb211dc83238897ffe))
* **windows:** Escriba on Windows with native Whisper and diarization ([aeec24a](https://github.com/Zetesis-Labs/escriba/commit/aeec24a766d8bea08705377b6642c2f34d6c3d3a))


### Bug Fixes

* **audio:** keep the error when rejecting non-regular files ([cc6aa91](https://github.com/Zetesis-Labs/escriba/commit/cc6aa9136484cec61b719aad7ed78b4f95ee81c2))
* **library:** right-click no longer clears the multiple selection, and Rust lets combineAudio through ([81c1ad1](https://github.com/Zetesis-Labs/escriba/commit/81c1ad1c2a8dbe5a032b199fe0806829ae5946f9))
* **ci:** fix the isolated build and test failures ([29fa024](https://github.com/Zetesis-Labs/escriba/commit/29fa024cdeec38b889df5012a37cb55371283ec8))
* **ci:** fix Windows paths and inference portability ([96812fb](https://github.com/Zetesis-Labs/escriba/commit/96812fb9d9cbf5955b6e39b258ee3e6bd356921c))
* **ci:** discard an incomplete sherpa extraction ([32f1edd](https://github.com/Zetesis-Labs/escriba/commit/32f1edd40f7b817e40a9f926fe61159cd809c73c))
* **ci:** install the pinned Bun version on Windows ([f92d375](https://github.com/Zetesis-Labs/escriba/commit/f92d375878372dc297f35672a0d4b5f11449e14a))
* **ci:** restore the sherpa libraries after restoring the cache ([35654c8](https://github.com/Zetesis-Labs/escriba/commit/35654c8ddf675e8482e27bebc6b9fb96800a5551))
* **recipes:** a note's first version is current, and the same note is the same object in the recipe ([1e092f2](https://github.com/Zetesis-Labs/escriba/commit/1e092f26933bd0ded2f433c4d5f9babae6fccacb))
* **recipes:** a run that does not transcribe does not change the note's status, and relaunching repeats its recipe ([e057be1](https://github.com/Zetesis-Labs/escriba/commit/e057be1a9d7ed0444132ca84d4e62566f3c1aef9))
* **tests:** on macOS, wait for RocksDB to release its LOCK before deleting the database ([f49878a](https://github.com/Zetesis-Labs/escriba/commit/f49878a64b39ab99ec617f3847b1fc06a6e77d86))
* **windows:** handle Bun dependencies across drives ([8746e15](https://github.com/Zetesis-Labs/escriba/commit/8746e15d4b1711113df737b191cc502ff8dad2e0))
* **windows:** resolve isolated paths without querying the volume manager ([b884a5e](https://github.com/Zetesis-Labs/escriba/commit/b884a5e919f764f1d663cf43e043d3abfc66aeab))

## [0.2.0](https://github.com/Zetesis-Labs/escriba/compare/v0.1.0...v0.2.0) (2026-10-15)


### Features

* add, download, delete and remove Whisper models from STT ([fab80c0](https://github.com/Zetesis-Labs/escriba/commit/fab80c05d5bd19f407bfefe20142f591aca065e9))
* each local Whisper transcribes with its own model and records it in the fingerprint ([92474d1](https://github.com/Zetesis-Labs/escriba/commit/92474d19b2280d9d41f95d2f12bce838cea53a31))
* **linux:** open in VS Code through its vscode:// address ([131c538](https://github.com/Zetesis-Labs/escriba/commit/131c538d4088148431ea652fe0348366d092e48d))
* **linux:** Settings without Voice Memos, folder authorization or Full Disk Access ([d3f503f](https://github.com/Zetesis-Labs/escriba/commit/d3f503f4e23af7b755e04f66bdfd9aa0bb26e2d4))
* **linux:** permanent warning in Recipes while the system cannot isolate them ([fc1c748](https://github.com/Zetesis-Labs/escriba/commit/fc1c74891e5403f3a5742766b548c8fe014c0936))
* **linux:** GNOME-style header bar instead of the Mac one ([8745975](https://github.com/Zetesis-Labs/escriba/commit/87459758388c8b36901fcc6d8ee57c75fe715869))
* **linux:** watched folders without bookmarks and without Voice Memos ([ed31b2c](https://github.com/Zetesis-Labs/escriba/commit/ed31b2c3fe8b5cea99dbdbb07fec34cf13038e93))
* **linux:** Whisper model catalog and per-model deletion in the host ([8721fb3](https://github.com/Zetesis-Labs/escriba/commit/8721fb37d22686ff7198965359c0cd27467fdd4d))
* **linux:** inside Flatpak each folder is authorized through the portal, as on the Mac ([5509c3d](https://github.com/Zetesis-Labs/escriba/commit/5509c3d08a518a41fc05e2320fdd64bee4c97960))
* **linux:** detect speakers with sherpa-onnx in the native host ([01c8f0b](https://github.com/Zetesis-Labs/escriba/commit/01c8f0b4e207ef0d6b103ce0c5a25c35ae50bf60))
* **linux:** run recipes and tools unisolated while Linux does not allow isolation ([823cb3c](https://github.com/Zetesis-Labs/escriba/commit/823cb3ca26d84109a0f0fef479b78e0dd8e7e353))
* **linux:** the recording panel goes inside the window ([4c9dc71](https://github.com/Zetesis-Labs/escriba/commit/4c9dc7162ed4b74030cbb7033a6b627467a89454))
* **linux:** choose and restore folders without bookmarks ([bbc29e5](https://github.com/Zetesis-Labs/escriba/commit/bbc29e5f2743b99c536fd852660fb24897a32aa5))
* **linux:** in Flatpak, Settings offers to authorize a folder again ([302b9d2](https://github.com/Zetesis-Labs/escriba/commit/302b9d2c65a32f900771f11a6e07afdf4c97a760))
* **linux:** escriba-sandbox enforces the Mac profiles with Landlock and seccomp ([c166731](https://github.com/Zetesis-Labs/escriba/commit/c1667312784d3d7f1a1e9c6863cb6c9b59030872))
* **linux:** file status without SF_DATALESS ([d6900c1](https://github.com/Zetesis-Labs/escriba/commit/d6900c1dcb82d4e8d1605112743aac30416131f5))
* **linux:** record in Opus from the Rust native host ([1c9efdc](https://github.com/Zetesis-Labs/escriba/commit/1c9efdcbbce1e5c17a6695d69c4bfa3261512c00))
* **linux:** minimal native host in Rust ([1da4d3c](https://github.com/Zetesis-Labs/escriba/commit/1da4d3cbfaf888db113f13ebc5e7e8f61225c8ae))
* **linux:** tray icons drawn without SF Symbols ([4656798](https://github.com/Zetesis-Labs/escriba/commit/4656798bf081c28deb6a290224d222d77a6efd4a))
* **linux:** start at login through the Background portal inside Flatpak ([7701fda](https://github.com/Zetesis-Labs/escriba/commit/7701fda7cc64f3bfbfa276d7f53163aa02b8b059))
* **linux:** large-v3-turbo as the default Whisper ([559b514](https://github.com/Zetesis-Labs/escriba/commit/559b5141c23b48e22fb8e8f3fb5899dd69ef18ab))
* **linux:** recordings are saved as .ogg ([9398936](https://github.com/Zetesis-Labs/escriba/commit/9398936202c173bed2d7710ef353830595532af5))
* **linux:** worker memory and identity from /proc ([1bad9c3](https://github.com/Zetesis-Labs/escriba/commit/1bad9c361b21abe201b02172f0f47ac90a09e8ab))
* **linux:** platform module for opening, revealing, models and permissions ([b0b678c](https://github.com/Zetesis-Labs/escriba/commit/b0b678c21c1aeda941f5df26c5a86511f22c038f))
* **linux:** desktop notifications ([7737161](https://github.com/Zetesis-Labs/escriba/commit/773716199e18341773b271677685df4d6ca017c2))
* **linux:** floating recording panel with its own background ([41e03fd](https://github.com/Zetesis-Labs/escriba/commit/41e03fd3231f7415e9fdc6bc8dc03bc7efb0bd1a))
* **linux:** project recipes and tools isolated with escriba-sandbox ([dd6486d](https://github.com/Zetesis-Labs/escriba/commit/dd6486d78dfc4226fe7027a6d1bc7f631aae1d46))
* **linux:** summarizing without a chosen LLM fails saying what is missing ([ca5f131](https://github.com/Zetesis-Labs/escriba/commit/ca5f131f02d322c205ba674db4d12221edf35f50))
* **linux:** no menu bar inside the window ([3381aec](https://github.com/Zetesis-Labs/escriba/commit/3381aec5911c928428cf9a6d9e8477ab20cbb7f0))
* **linux:** without a GPU, WebKitGTK renders in software ([dfa1991](https://github.com/Zetesis-Labs/escriba/commit/dfa199185d307e4572698fc83bbb4cf50f240a98))
* **linux:** interface texts according to the system ([1270184](https://github.com/Zetesis-Labs/escriba/commit/1270184894c007b150f82b3c9d8ac09f2a74cd27))
* **linux:** development target triple according to the build target ([4f6d4d5](https://github.com/Zetesis-Labs/escriba/commit/4f6d4d547499077943efbdd1fe9f7dfdb309ee17))
* **linux:** defaults without a bundled LLM, and the platform exposed to the interface ([046ed33](https://github.com/Zetesis-Labs/escriba/commit/046ed332516568e333e130534587921299dcc430))
* **linux:** integrated window as on macOS ([d3ae32d](https://github.com/Zetesis-Labs/escriba/commit/d3ae32d7e1c284657959c218b0dd55877c1a93ba))
* **linux:** local Whisper with whisper.cpp in the native host ([7b27d68](https://github.com/Zetesis-Labs/escriba/commit/7b27d68ade66ed2847783b2facfb9dba287bb666))
* added Whisper models are local resolvers ([bdcd269](https://github.com/Zetesis-Labs/escriba/commit/bdcd269396387a1bc0012b5ff239a16cd0597aa5))
* **people:** each voiceprint model recognizes with its own threshold ([b256410](https://github.com/Zetesis-Labs/escriba/commit/b25641049af84c601eb48047df521098cab1638d))
* **stt:** the default Whisper can be removed, and a recipe without STT uses the first local Whisper ([3f9f429](https://github.com/Zetesis-Labs/escriba/commit/3f9f4291b625eb50b2fea07f9ba1a31444419aba))
* whisper_model works per model and the interface can request the catalog ([1cd0313](https://github.com/Zetesis-Labs/escriba/commit/1cd0313bcb96f83ac4038c1e9642ab6e35fe2c27))


### Bug Fixes

* **library:** a pending deletion tells a new file apart even if it reuses the inode ([66604ff](https://github.com/Zetesis-Labs/escriba/commit/66604ffe3b5000dd64a99ce9449770cf97ceda59))
* **library:** read a note and its versions in a single transaction ([24d842f](https://github.com/Zetesis-Labs/escriba/commit/24d842f43b32e34b1ef2d8afb7a8390c20464273))
* Download shows the size of each Whisper model ([19ab17a](https://github.com/Zetesis-Labs/escriba/commit/19ab17a00eb9b2c516fe6f2c8e4209671482caf8))
* **linux:** clippy on arm64, where the list of blocked calls does not grow ([c60ddb1](https://github.com/Zetesis-Labs/escriba/commit/c60ddb199f555b2868e32fc9814c12565b1f18c4))
* **linux:** the Flatpak starts: no strip, and with the AppIndicator tray ([7c8de22](https://github.com/Zetesis-Labs/escriba/commit/7c8de224c1f155907715ef7c510149025cbc4dc7))
* **linux:** the Flatpak disables WebKitGTK's dmabuf rendering ([f329553](https://github.com/Zetesis-Labs/escriba/commit/f3295535fd28ab22cf67422f29ded257dd69440f))
* **linux:** the Flatpak redraws the whole window without WebKit's accelerated compositing ([e6d1d71](https://github.com/Zetesis-Labs/escriba/commit/e6d1d7170109a2f5e9665a793014d5ae1c47e877))
* **linux:** the recording panel keeps the height of the pill ([c63929f](https://github.com/Zetesis-Labs/escriba/commit/c63929f6dfe5e72ceb872f87b2e526c3f93c9e54))
* **linux:** the recording panel is centered over the content ([51f61c0](https://github.com/Zetesis-Labs/escriba/commit/51f61c07c622acaac48a079160ac7554fa5f241f))
* **linux:** in tests, wait until RocksDB really releases its lock ([f51f958](https://github.com/Zetesis-Labs/escriba/commit/f51f958011726869668f492aaed4bf277938672e))
* **linux:** start at login without the macOS launcher ([76326fd](https://github.com/Zetesis-Labs/escriba/commit/76326fd4594bc2fabed6c9603cf6665c151ba6d5))
* **linux:** the default recipe works without LLMs ([6c4b06c](https://github.com/Zetesis-Labs/escriba/commit/6c4b06cb5853fe46f788142abe8cd819aed4122d))
* **linux:** tray icons show up from Flatpak ([b713f40](https://github.com/Zetesis-Labs/escriba/commit/b713f4073dbdf5a732085b8d054a442c21b90918))
* **linux:** no gap for the Mac window buttons over the sidebar ([5a53756](https://github.com/Zetesis-Labs/escriba/commit/5a537561687c85bfa483f19d2d067080d1dcbc77))
* **tests:** fully close each RocksDB database when its test ends ([dfbe6cc](https://github.com/Zetesis-Labs/escriba/commit/dfbe6ccc4494420e3afd68fd12f568ede129789a))


### Reverts

* CI runs only on main and on pull requests again ([10b5acf](https://github.com/Zetesis-Labs/escriba/commit/10b5acf2b1b3b4cb239b3b99eeae8f8dc69dccfb))
