import { z } from 'zod';

export const receta = {
  nombre: 'Consultar y anotar en el servicio de ejemplo',
  datos: z.object({ consulta: z.string().min(1) }),
};

export async function flujo(audio: unknown, api: {
  transcribir(audio: unknown): Promise<{ texto: string; guardar(): Promise<void> }>;
  cuenta(id: string): { fetch: typeof fetch };
}) {
  const nota = await api.transcribir(audio);
  const cuenta = api.cuenta('mi-cuenta-sintetica');
  const consulta = await cuenta.fetch('https://api.example.test/me');
  if (!consulta.ok) throw Error(`Consulta fallida: ${consulta.status}`);
  const cambio = await cuenta.fetch('https://api.example.test/drafts', {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ text: nota.texto }),
  });
  if (!cambio.ok) throw Error(`Escritura fallida: ${cambio.status}`);
  await nota.guardar();
}
