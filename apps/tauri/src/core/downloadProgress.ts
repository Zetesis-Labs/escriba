export function progressForModel(payload: { model: string; fraction: number }, model: string): number | null {
  const { fraction } = payload;
  return payload.model === model && Number.isFinite(fraction) && fraction >= 0 && fraction <= 1 ? fraction : null;
}
