import { createProgram, defineProvider, type Configuration, type Request, type Host } from '@escriba/conectores';
import { z } from 'zod';

const origin = 'https://api.example.test';
const configurationSchema = z.object({ workspace: z.string().min(1), collection: z.string().min(1) });
const defaults = { workspace: 'demo', collection: 'notes' };

function path(value: string) { return encodeURIComponent(value); }
async function json(response: Response) {
  if (!response.ok) throw Error(`El servicio respondió ${response.status}`);
  return response.json() as Promise<unknown>;
}
function options(value: unknown): Array<{ id: string; name: string }> {
  if (!Array.isArray(value)) throw Error('Respuesta de colecciones no válida');
  return value.flatMap((item) => item && typeof item === 'object' && 'id' in item && 'name' in item && typeof item.id === 'string' && typeof item.name === 'string' ? [{ id: item.id, name: item.name }] : []);
}
function describe(config: Configuration, state: Configuration) {
  const collections = options(state.collections ?? []);
  return { view: { sections: [{ title: 'Colección', fields: [
    { type: 'text' as const, path: ['workspace'], label: 'Espacio de trabajo' },
    { type: 'action' as const, id: 'refresh-collections', label: 'Actualizar colecciones' },
    { type: 'select' as const, path: ['collection'], label: 'Guardar en', options: collections.map((item) => ({ label: item.name, value: item.id })) },
  ] }], subtitle: String(config.collection || 'Sin colección elegida') } };
}
async function publish(request: Request, host: Host, config: z.infer<typeof configurationSchema>) {
  if (!request.note) throw Error('Falta la nota');
  const key = request.note.key;
  const base = `${origin}/workspaces/${path(config.workspace)}/collections/${path(config.collection)}/notes`;
  let locator = request.previous?.locator;
  if (!locator) {
    const lookup = await host.fetch(`${base}/by-key/${path(key)}`);
    const found = lookup.status === 404 ? null : await json(lookup);
    if (found && typeof found === 'object' && 'id' in found && typeof found.id === 'string') locator = found.id;
  }
  if (!locator && request.previous?.state === 'creating') throw Error('La creación sigue sin confirmar; reconcilia antes de publicar de nuevo');
  if (!locator) {
    await host.checkpoint({ version: 1, provider: 'synthetic-notes', locator: '', key, state: 'creating' });
    const created = await json(await host.fetch(base, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ key, text: request.note.text }) }));
    if (!created || typeof created !== 'object' || !('id' in created) || typeof created.id !== 'string') throw Error('Respuesta de creación no válida');
    locator = created.id;
    await host.checkpoint({ version: 1, provider: 'synthetic-notes', locator, key });
  } else {
    const updated = await host.fetch(`${base}/${path(locator)}`, { method: 'PUT', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ key, text: request.note.text }) });
    if (!updated.ok) throw Error(`Actualización fallida: ${updated.status}`);
  }
  return { locator, receipt: { version: 1 as const, provider: 'synthetic-notes', locator, key } };
}

const provider = defineProvider({
  manifest: {
    id: 'synthetic-notes', name: 'Notas de ejemplo', capability: 'http', origin,
    allowedHeaders: ['content-type', 'accept'],
    credential: { label: 'Clave del servicio', header: 'X-API-Key' },
    defaultConfiguration: defaults,
    description: 'Ejemplo de proyecto externo con colecciones cargadas desde su cuenta.',
  },
  configurationSchema,
  describe,
  async action(configuration, state, action, _value, host) {
    if (action !== 'refresh-collections' || !host) throw Error('Acción no disponible');
    const workspace = String(configuration.workspace || '');
    if (!workspace) throw Error('Elige el espacio de trabajo');
    const collections = options(await json(await host.fetch(`${origin}/workspaces/${path(workspace)}/collections`, { headers: { accept: 'application/json' } })));
    const nextState = { ...state, collections };
    return { state: nextState, ...describe(configuration, nextState) };
  },
  async run(request, host) {
    if (!host) throw Error('Falta el host de capacidades');
    const config = configurationSchema.parse(request.config);
    if (request.operation === 'publish') return publish(request, host, config);
    if (request.operation === 'remove') {
      const locator = request.previous?.locator;
      if (!locator) throw Error('Falta el localizador de la publicación');
      const url = `${origin}/workspaces/${path(config.workspace)}/collections/${path(config.collection)}/notes/${path(locator)}`;
      const deleted = await host.fetch(url, { method: 'DELETE' });
      if (!deleted.ok) throw Error(`Retirada fallida: ${deleted.status}`);
      return { locator };
    }
    throw Error(`Operación no implementada: ${request.operation}`);
  },
});

const program = createProgram([], [provider]);
export const inspect = program.inspect;
export const run = program.run;
