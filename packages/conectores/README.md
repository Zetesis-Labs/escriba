# @escriba/conectores

Las publicaciones de Notion y OKF se ejecutan en TypeScript. El host proporciona
HTTP, acceso a una carpeta, el audio y persistencia del recibo. No contiene
credenciales, endpoints de proveedor ni reglas de formato fuera de este paquete.

`run(request, host)` es la interfaz de compatibilidad con las configuraciones
anteriores. `manifest`, `validate` y la migración de configuración son operaciones
sin efectos externos. `preview` admite una nota o usa el ejemplo de la app.
`discover` lista fuentes de Notion o documentos OKF. `publish` y `remove` ejecutan
los efectos y devuelven `{ locator, url?, receipt }`.

```ts
import { createProgram, defineNotionDestination } from '@escriba/conectores';

const program = createProgram([
  defineNotionDestination({
    id: 'actas',
    name: 'Actas del equipo',
    account: 'mi-cuenta',
    configuration: {
      source: {
        id: 'data-source-id',
        title: 'Actas',
        properties: [{ name: 'Nombre', type: 'title' }],
      },
      columns: { Nombre: '{{titulo}}' },
      body: '# Resumen\n{{resumen}}\n# Texto\n{{transcripcion}}',
    },
  }),
]);

export const inspect = program.inspect;
export const run = program.run;
```

`defineOKFDestination` usa el mismo contrato. Su configuración contiene `folder`
y opcionalmente `documents`, con `id`, `name`, `path`, `properties` y `body`.
Los IDs existentes se conservan y las referencias `{{enlace:id}}` se resuelven
antes de aplicar cambios. Un destino puede declarar `inputSchema` con Zod y
`prepare(input, request)` para convertir datos propios a la nota publicada.

El host debe guardar cada `checkpoint` de forma duradera antes de resolverlo y
serializar las operaciones que comparten destino o carpeta. El recibo es opaco
para el host. OKF guarda huellas SHA-256 de todas sus rutas y del plan pendiente;
una escritura interrumpida se reanuda usando ese recibo. Una edición manual de un
documento publicado hace fallar la operación antes de modificar la carpeta.
Cambiar la carpeta de un recibo exige resolver el traslado explícitamente.

Notion usa el SDK oficial, en lotes de cien bloques. Antes de crear una página
se guarda un recibo con `state: 'creating'` y `locator: ''`; el host también debe
persistirlo. Después de crearla se guarda el localizador inmediatamente. Si se
pierde la respuesta de creación, otra ejecución busca la columna de clave y
continúa con la página encontrada. Si no puede reconciliarla, devuelve un error
explícito y no vuelve a crear a ciegas. El recibo puede completarse con el
localizador verificado mediante una acción explícita de reconciliación del host.

El SDK reintenta 429 y 529, y errores 500/503 solo para GET y DELETE. No reintenta
creaciones ante errores de red. El audio usa una parte hasta 20 MiB y partes de
10 MiB por encima de ese tamaño. Las credenciales se inyectan en el transporte
HTTP del host; este paquete nunca recibe tokens.

## Desarrollo

```sh
./scripts/build-conectores.sh
```

El script instala desde el lockfile sin ejecutar scripts npm, verifica las
pruebas con transporte y carpeta en memoria, y genera tipos, módulos ESM y
`dist/conectores.js` (`globalThis.__conectores`). La app ejecuta los programas
con el Bun incluido, en procesos aislados y con capacidades del host Rust.

Las pruebas no llaman a servicios reales. La validación contra Notion real con
datos sintéticos sigue pendiente de la autorización de esa fase.

## Proveedores del proyecto

`createProgram(destinos, proveedores)` permite declarar proveedores desde un proyecto externo. Un proveedor define su manifiesto de acceso, la configuración ordinaria con Zod, los formularios que Escriba muestra y sus operaciones. La credencial se declara en `manifest.credential` y la conserva el host; no forma parte de `defaultConfiguration` ni se entrega al programa.

```ts
import { z } from 'zod';
import { createProgram, defineProvider } from '@escriba/conectores';

const synthetic = defineProvider({
  manifest: {
    id: 'synthetic', name: 'Synthetic', capability: 'http',
    origin: 'https://example.test', allowedHeaders: ['content-type'],
    credential: { label: 'Clave', header: 'Authorization', prefix: 'Bearer ' },
    defaultConfiguration: { project: 'demo' },
  },
  configurationSchema: z.object({ project: z.string().min(1) }),
  describe: (configuration) => ({
    view: { sections: [{ title: 'Proyecto', fields: [
      { type: 'text', path: ['project'], label: 'Proyecto' },
    ] }] },
  }),
  run: async (request, host) => {
    if (!host) throw Error('Falta el host de capacidades');
    const response = await host.fetch('https://example.test/projects/' + request.config?.project);
    return { resource: await response.json() };
  },
});

const program = createProgram([], [synthetic]);
export const inspect = program.inspect;
export const run = program.run;
```

`inspect()` devuelve proveedores y destinos serializables. `run({ operation: 'describe', provider, config, state })` entrega una `view` declarativa sin autoridad del host. `action` puede consultar el servicio mediante `host.fetch` y devolver `{ configuration, state, view }`; `state` conserva sólo selección temporal y opciones, nunca credenciales. `validate` comunica los campos inválidos por su ruta Zod. Las operaciones de cuenta y publicación se delegan a `run` del proveedor. Los proveedores incorporados Notion y OKF usan este mismo contrato de formularios.

`manifest.connectAction` indica la acción que se ejecuta tras guardar una credencial nueva; Notion usa `refresh-sources`. Los selectores cuyo valor vive en el estado temporal pueden declarar `field.value` aunque `field.path` esté vacío. La definición acepta instancias de Zod instaladas por el proyecto externo; su esquema debe ofrecer `parse`, `safeParse` y `toJSONSchema`.

El [proyecto externo de ejemplo](../../examples/conectores/README.md) muestra un proveedor con opciones dinámicas, clave de API, publicación con recibo y una receta que consulta y escribe mediante la cuenta autorizada.
