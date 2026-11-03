export function progressForModel(payload: { model: string; fraction: number }, model: string): number | null {
  const { fraction } = payload;
  return payload.model === model && Number.isFinite(fraction) && fraction >= 0 && fraction <= 1 ? fraction : null;
}

// Downloads outlive the screen that started them: whoever opens the model later sees its progress.
export function createDownloads() {
  const fractions = new Map<string, number>();
  const failures = new Map<string, string>();
  const subscribers = new Set<() => void>();
  const changed = () => {
    for (const subscriber of subscribers) subscriber();
  };
  return {
    begin(model: string) {
      if (fractions.has(model)) return false;
      failures.delete(model);
      fractions.set(model, 0);
      changed();
      return true;
    },
    progress(payload: { model: string; fraction: number }) {
      const current = fractions.get(payload.model);
      const fraction = progressForModel(payload, payload.model);
      if (current === undefined || fraction === null || fraction <= current) return;
      fractions.set(payload.model, fraction);
      changed();
    },
    end(model: string, failure?: string) {
      fractions.delete(model);
      if (failure) failures.set(model, failure);
      changed();
    },
    fraction: (model: string) => fractions.get(model) ?? null,
    failure: (model: string) => failures.get(model) ?? null,
    subscribe(subscriber: () => void) {
      subscribers.add(subscriber);
      return () => {
        subscribers.delete(subscriber);
      };
    },
  };
}
