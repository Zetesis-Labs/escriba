# RocksDB como motor de SurrealDB

Decidido por Rubén el 2026-10-12, tras medir los dos motores con una copia de
su biblioteca. Sustituye a SurrealKV, elegido en el ADR-0003.

SurrealKV 0.21.4 no recupera el espacio de lo borrado en la práctica. Los
valores de más de 4 KiB van a un registro de valores que solo se borra por
ficheros enteros más antiguos que el valor vivo más antiguo, y SurrealDB 3.3.2
no ofrece compactación con este motor (`ALTER SYSTEM COMPACT` responde que no
está soportada). La base retirada del grafo dejó 2,2 GB que solo se
recuperaron reconstruyendo el fichero.

Medido con los mismos datos y SurrealDB 3.3.2:

| | SurrealKV | RocksDB |
|---|---|---|
| Biblioteca recién importada | 57 MB | 20 MB |
| Biblioteca reescrita entera 3 veces | 230 MB | 18 MB |
| Biblioteca tras borrar sus tablas | 225 MB | 0 MB |
| Grafo tras `ALTER SYSTEM COMPACT` | no soportado | 10 MB |
| Proyección de la base (depuración) | 36 s | 39 s |

RocksDB comprime los niveles inferiores (LZ4 y Zstd), compacta solo cada hora
y atiende la compactación oficial. Cuesta compilar C++ y aumenta el tamaño de
la app. Se pierde el versionado de SurrealKV, que Escriba no usaba.

Al abrir, `storage::open` convierte `library.surrealkv` y `knowledge.surrealkv`
en `library.rocksdb` y `knowledge.rocksdb`: exporta cada base con el SDK, la
importa, redefine el acceso de recetas (la exportación oculta su clave),
compara definiciones y registros de cada tabla y compacta. Solo entonces
renombra el original a `*.surrealkv.convertida`, que se conserva. Si algo
falla, el original sigue con su nombre y el siguiente arranque descarta lo
convertido y lo rehace; nunca se abre una base vacía en su lugar. Con la
biblioteca de Rubén: 242 grabaciones, 234 versiones y 25 trabajos intactos,
82 → 18 MB; grafo con 199 notas y su ontología, 80 → 10 MB.
