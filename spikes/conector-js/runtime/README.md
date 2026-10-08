# Host desechable

`swift -module-cache-path .scratch/swift-module-cache runtime/run.swift bundle.js input.json output.json http://127.0.0.1:PORT`

Ejecuta JavaScriptCore del sistema, sin Node. El paquete IIFE exporta
`__destino.run(input, contexto)`. El contexto contiene `cuenta.fetch` y
`checkpoint(receipt)`. El resultado es `{ok,result?,error?,checkpoints,audit}`;
un error conserva los checkpoints anteriores y termina con código 1.
Cada checkpoint se escribe primero atómicamente en
`output.json.checkpoints.json`. `input.crashAfterCheckpoint` termina el proceso
con código 86 inmediatamente después de esa escritura para comprobar la
recuperación. Es un journal desechable local, no una base de datos.

El transporte solo admite el origen HTTP loopback concedido. Swift añade una
credencial ficticia fija, rechaza cabeceras de autenticación/transporte del
paquete, desactiva cookies, caché, proxies y redirecciones. Ninguna credencial
real se lee. `input.revoked` rechaza todas las llamadas. El host no conoce los
endpoints de Notion ni interpreta sus cuerpos. El multipart se serializa en
Swift desde nombres, valores y bytes, sin acceso a ficheros del paquete.
Solo se admiten GET/POST/PATCH/DELETE; un 3xx se rechaza expresamente. Las
respuestas mayores de 8 MiB se rechazan tras recibirse: no limita el pico de
memoria de la descarga.

Los callbacks de red solo escriben mensajes con datos en un buzón protegido;
el hilo propietario del contexto entrega las promesas. Las referencias JS
permanecen en JavaScriptCore. Hay cancelación de tareas HTTP mediante
AbortController, cancelación de timers, deadline de pared de 30 s y límite de
ejecución JS de 5 s mediante la API privada ya explorada en el proyecto.

La compatibilidad es deliberadamente parcial: URL/URLSearchParams cubren el
constructor y la query que usa el SDK; Blob/File/FormData cubren bytes en
memoria y multipart; Headers cubre get/set/iteración. No son implementaciones
WHATWG completas. No hay `fetch` global, streams, fs, process ni require.
Console es silenciosa; solo se escribe el resultado estructurado.

Se eliminan cabeceras sensibles de respuestas y se sustituye el literal de
la credencial ficticia en texto y salidas. Esta comprobación no demuestra
aislamiento contra un servidor malicioso que codifique el secreto de otra
forma. Tampoco se ha convertido este script en un sandbox de producción.
