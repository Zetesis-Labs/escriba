import { DateTime, RecordId } from "surrealdb";

export const receta = { nombre: "Reunión con un acuerdo de ejemplo" };

export const ontologias = [
  { id: "ejemplo.reuniones", minVersion: 1, maxVersion: 1 },
] satisfies readonly DependenciaDeOntologia[];

export async function flujo(audio: Audio, api: Escriba) {
  const db = await api.grafo("ejemplo.reuniones");
  const nota = await api.transcribir(audio);
  await nota.guardar();

  const reunionId = new RecordId("reunion", `${audio.clave}-${nota.version}`);
  const acuerdoId = new RecordId("acuerdo", `${audio.clave}-${nota.version}`);
  const relacionId = new RecordId("surgio_en", `${audio.clave}-${nota.version}`);
  const primerEnunciado = nota.texto.split(/[.!?]/, 1)[0]?.trim();
  const tituloAcuerdo = primerEnunciado || "Revisar la transcripción";

  await db.create(reunionId).content({
    titulo: audio.nombre,
    fecha: new DateTime(audio.fecha),
  });
  await db.create(acuerdoId).content({ titulo: tituloAcuerdo, estado: "pendiente" });
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
