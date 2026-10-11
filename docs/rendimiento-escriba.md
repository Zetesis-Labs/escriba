# Tamaño y memoria de Escriba

Medición local del 2026-10-10 en Apple Silicon, macOS 27.0, con 48 GiB de RAM.
La referencia es la release de `b8d1092`, instalada como `/Applications/Escriba.app`.
La biblioteca contiene 242 grabaciones, incluidas las descartadas, y 218
versiones; se conservan 195 archivos de audio local.

## Cambios medidos

- Release Rust con `strip = "symbols"`, `lto = "thin"` y `codegen-units = 1`.
- Retirada del plugin de notificaciones sin consumidores; la entrega nativa
  mediante `UNUserNotificationCenter` permanece.
- Grabaciones y transcripciones tipadas en memoria, evitando mapas JSON por
  segmento y palabra. La vista de biblioteca construye directamente su
  representación ligera, sin copiar primero transcripciones ni programas.
- La persistencia recibe las representaciones anterior y nueva por movimiento;
  al separar filas de grabación omite versiones y publicaciones antes de copiar.

## Procedimiento

Cerrar y abrir la app instalada, mantener su ventana en Biblioteca y dejarla
cinco minutos sin interacción. Se conserva la vigilancia normal de carpetas;
no se solicita transcripción, inferencia ni publicación. El muestreo incluye el
proceso Rust, sus auxiliares y los procesos WebKit de su coalición macOS.

```sh
python3 scripts/measure-app.py --duration 300 --interval 30 --output /tmp/escriba-idle.json
```

El script usa `ps`, `lsappinfo` y `footprint`, sin abrir la biblioteca ni leer
contenido de las notas. Comprueba que el proceso principal no se reinicie y que
se midan todos los procesos seleccionados. El tamaño es la suma lógica de los
archivos regulares del bundle; MiB significa 1.048.576 bytes.

`footprint` es la memoria que macOS imputa a los procesos, incluida su
contabilidad de memoria comprimida. Se informa también RSS por separado:
puede incluir páginas compartidas o recuperables y no equivale a `footprint`.
Las cifras son una observación con esta biblioteca y este Mac, no un límite de
consumo ni una prueba de carga. La referencia se tomó con comprobaciones de
desarrollo en paralelo, por lo que la presión de memoria no está controlada.

## Resultados

Referencia tras 300,40 segundos de muestreo, unos 345 segundos desde el
arranque; nueva release tras 300,26 segundos de muestreo y 352,21 segundos
desde el arranque. Las muestras finales son de las 23:15:46 y 23:54:36 CEST,
respectivamente.

| Medida | Antes | Después |
| --- | ---: | ---: |
| Bundle completo | 233,54 MiB | 170,69 MiB |
| Ejecutable Rust | 124,43 MiB | 61,58 MiB |
| `footprint` de app y auxiliares | 728,26 MiB | 290,40 MiB |
| `footprint` de Rust | 621,22 MiB | 201,83 MiB |
| RSS agregado | 3762,94 MiB | 3869,88 MiB |

El bundle pasa de 244.880.570 a 178.984.794 bytes: 26,91 % menos. En estas
mediciones, el `footprint` final baja un 60,12 %. RSS no baja; no debe confundirse
esa cifra con la memoria imputada por macOS ni atribuir toda la diferencia a
un único cambio de código. La comparación de memoria es orientativa por las
condiciones de presión descritas arriba.

La muestra final nueva se reparte entre Rust (201,83 MiB), contenido WebKit
(53,47), GPU WebKit (17,38), Bun (12,30) y red WebKit (5,42). El host nativo ya
se había descargado por inactividad. El máximo de `footprint` del proceso Rust
desde su arranque era 2990,41 MiB antes y aproximadamente 1,8 GiB después,
según `vmmap`; el reposo no representa ese pico de carga inicial.

Registros locales: `/tmp/escriba-idle-before.json` y
`/tmp/escriba-idle-after.json`. La instancia nueva conservó el mismo PID durante
toda la medición. La instalación verificó firma estricta e igualdad del bundle
construido e instalado; conserva la versión anterior en
`.build/Escriba-anterior.app`. Se guardó una copia consistente de la biblioteca
con la app cerrada antes de sustituirla. Los 195 audios siguen presentes tras
la medición. La comprobación manual de uso de esta instalación queda pendiente
de Rubén.

## Carga diferida de transcripciones (2026-10-11)

El reposo estable de la release anterior no demostraba un arranque barato:
`Store` seguía leyendo y conservando todas las transcripciones. Ahora conserva
un índice ligero, consulta el documento completo de una nota solo al abrir su
detalle o trabajar con ella y limita las escrituras de contenido a esa nota.
Las proyecciones se guardan en tablas pequeñas separadas y se confirman con el
documento completo en una misma transacción de SurrealDB. `EXPLAIN ANALYZE`
confirmó que `parent = $parent` producía `TableScan` en SurrealDB 3.3.2; el
literal codificado con el serializador JSON permite `IndexScan`. La regresión
y el escape de caracteres especiales tienen pruebas sintéticas.

Una sonda de `Store::open` en procesos de pruebas nuevos, sobre la misma copia
privada de 242 grabaciones y 218 versiones, pasó de 1.241.893.216 bytes de
`footprint` en reposo inmediato (1.184,36 MiB) a 58.049.304 (55,36 MiB), un
95,33 % menos. La lectura nueva tardó unos 0,4 segundos; el máximo de RSS
observado antes de cerrar el almacén fue 99,38 MiB. Es una comparación del almacén en modo debug, sin
WebKit, vigilancia ni inferencia: no debe presentarse como consumo total de
la aplicación instalada.

La generación inicial de las proyecciones se mide aparte: recorre una versión
cada vez y tardó unos 12 segundos en esa copia. La comparación del arranque se
hizo en otro proceso sobre la copia ya preparada, para no atribuirle la memoria
temporal de esa preparación. Las sondas ignoradas de `store::measurement`
requieren `ESCRIBA_VERIFY_LIBRARY_COPY`, trabajan siempre en otra copia privada
y solo muestran recuentos, memoria y tiempos. No consultan la biblioteca viva.

El motor continúa siendo SurrealDB 3.3.2 con SurrealKV 0.21.4. No se redujo el
arena de escritura: el código fijado de SurrealKV escribe el WAL antes de
aplicar el lote al memtable y un lote superior a un límite reducido podría
fallar también al recuperarlo. La optimización evita cargar el contenido en
`Store`; no cambia límites ni durabilidad del motor.

La sonda detectó además un pico de 1.078,63 MiB de `footprint` al destruir
`Store` y cerrar SurrealDB, después de la medición de reposo. La cifra de
55,36 MiB no representa un límite de memoria ni elimina las asignaciones
transitorias del motor al cerrar.

### Release instalada y reposo de cinco minutos

Instalada y abierta el 2026-10-11. La firma estricta y la igualdad del bundle
construido e instalado pasaron. Tras la preparación inicial del índice se
reinició una vez; el PID 23050 permaneció estable durante los 300 segundos.
No se solicitó inferencia ni publicación. Los 195 audios siguen presentes.

| Medida | Release anterior, cinco minutos | Carga diferida, cinco minutos |
| --- | ---: | ---: |
| Bundle instalado | 170,69 MiB | 170,82 MiB |
| `footprint` de app y auxiliares | 290,40 MiB | 274,16 MiB |
| `footprint` de Rust | 201,83 MiB | 137,81 MiB |
| RSS agregado | 3869,88 MiB | 740,23 MiB |
| Pico de `footprint` de Rust desde el arranque (`vmmap`) | ~1,8 GiB | 337,6 MiB |

La reducción más marcada está en el pico de arranque. En estas muestras de
cinco minutos, el `footprint` total baja un 5,59 % y el de Rust un 31,72 %.
La presión de memoria y la actividad de WebKit no están controladas: no son
límites garantizados ni una atribución causal de cada MiB. Justo antes de
actualizar, la instancia anterior llevaba unas dos horas abierta y marcaba
375,90 MiB totales, de ellos 242,36 MiB de Rust; esa muestra tiene distinta
antigüedad y se conserva como referencia adicional.

Desglose final: Rust 137,81 MiB, contenido WebKit 99,75, GPU WebKit 18,50,
Bun 12,45 y red WebKit 5,64. El host nativo ya se había descargado por
inactividad. El bundle contiene 179.118.170 bytes. Registros locales:
`/tmp/escriba-lazy-before-installed.json`, `/tmp/escriba-lazy-first-launch.json`
y `/tmp/escriba-lazy-idle-after.json`.

Validación: 203 pruebas Rust, 199 TypeScript, tipos, Clippy y formato correctos.
La copia privada conservó todas las versiones y los recibos de 242 grabaciones
(218 versiones y 16 trabajos). Las pruebas cubren escrituras acotadas, rollback,
descartes, alias de recetas, carga del detalle e invalidación de su revisión.
La comprobación manual de esta instalación sigue pendiente de Rubén.
