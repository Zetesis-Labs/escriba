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
