import { DateTime, RecordId } from "surrealdb";

export const receta = { nombre: "Reunión con un acuerdo de ejemplo" };

export const ontologias = [
  { id: "ejemplo.reuniones", minVersion: 2, maxVersion: 2 },
] satisfies readonly DependenciaDeOntologia[];

export async function flujo(audio: Audio, api: Escriba) {
  const db = await api.grafo("ejemplo.reuniones");
  const nota = await api.transcribir(audio);
  await nota.guardar();
  const base = await api.grafo("escriba");
  const [grabaciones] = await base.query<[Array<{ currentVersion: RecordId | null }>]>(
    "SELECT currentVersion FROM recording WHERE id = $id",
    { id: new RecordId("recording", audio.clave) },
  );
  const versionId = grabaciones?.[0]?.currentVersion;
  if (!versionId) throw Error("La versión de la nota aún no está en la base de Escriba");
  const [segmentos] = await base.query<[Array<{ id: RecordId }>]>(
    "SELECT id FROM segment WHERE version = $version ORDER BY index LIMIT 1",
    { version: versionId },
  );
  const segmentoId = segmentos?.[0]?.id;
  if (!segmentoId) throw Error("La nota no tiene un segmento que referenciar");
  const segmento: ReferenciaDeConocimiento = {
    ontologyId: "escriba", table: "segment", id: segmentoId.toString(),
  };

  const reunionId = new RecordId("reunion", `${audio.clave}-${nota.version}`);
  const acuerdoId = new RecordId("acuerdo", `${audio.clave}-${nota.version}`);
  const relacionId = new RecordId("surgio_en", `${audio.clave}-${nota.version}`);
  const primerEnunciado = nota.texto.split(/[.!?]/, 1)[0]?.trim();
  const tituloAcuerdo = primerEnunciado || "Revisar la transcripción";

  await db.create(reunionId).content({
    titulo: audio.nombre,
    fecha: new DateTime(audio.fecha),
  });
  await db.create(acuerdoId).content({ titulo: tituloAcuerdo, estado: "pendiente", segmento });
  await db.relate(acuerdoId, relacionId, reunionId);

  const [relaciones] = await db.query<[Array<{ in: RecordId; out: RecordId }>]>(
    "SELECT in, out FROM surgio_en WHERE in = $acuerdo AND out = $reunion",
    { acuerdo: acuerdoId, reunion: reunionId },
  );
  if (!relaciones?.some((relacion) => relacion.in.toString() === acuerdoId.toString()))
    throw Error("No se guardó la relación del acuerdo");

  await nota.vincular("ejemplo.reuniones", reunionId.toString());
  await nota.vincular("ejemplo.reuniones", acuerdoId.toString());
  await nota.vincular("ejemplo.reuniones", relacionId.toString());
}
