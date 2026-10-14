// Each installed Whisper model is a local STT resolver; the default one keeps
// reading its model from the settings, as before several models existed.
const LOCAL_STT = "local-stt";
const MODEL = /^[A-Za-z0-9._-]+$/;

export const validModel = (model: string) => MODEL.test(model) && !model.includes("..");
export const localSttId = (model: string) => `${LOCAL_STT}-${model}`;
export const isLocalSttId = (id: string) =>
  id === LOCAL_STT || (id.startsWith(`${LOCAL_STT}-`) && validModel(id.slice(LOCAL_STT.length + 1)));

export function localModel(resolver: { id: string; model?: unknown }, whisperModel: string | null | undefined): string | null {
  if (resolver.id === LOCAL_STT) return whisperModel ?? null;
  return typeof resolver.model === "string" ? resolver.model : null;
}
