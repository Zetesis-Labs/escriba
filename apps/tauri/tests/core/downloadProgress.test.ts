import { describe, expect, it } from "vitest";
import { createDownloads, progressForModel } from "../../src/core/downloadProgress";

describe("progreso de descarga del modelo", () => {
  it("acepta solo fracciones válidas del modelo solicitado", () => {
    expect(progressForModel({ model: "large-v3", fraction: 0.4 }, "large-v3")).toBe(0.4);
    expect(progressForModel({ model: "small", fraction: 0.8 }, "large-v3")).toBeNull();
    expect(progressForModel({ model: "large-v3", fraction: 2 }, "large-v3")).toBeNull();
    expect(progressForModel({ model: "large-v3", fraction: Number.NaN }, "large-v3")).toBeNull();
  });

  it("una descarga empezada sigue a la vista para quien llegue después", () => {
    const downloads = createDownloads();
    downloads.begin("tiny");
    downloads.progress({ model: "tiny", fraction: 0.4 });
    expect(downloads.fraction("tiny")).toBe(0.4);
    expect(downloads.fraction("base")).toBeNull();
  });

  it("no empieza dos veces el mismo modelo", () => {
    const downloads = createDownloads();
    expect(downloads.begin("tiny")).toBe(true);
    expect(downloads.begin("tiny")).toBe(false);
    expect(downloads.begin("base")).toBe(true);
  });

  it("ignora el progreso de lo que no se está descargando y nunca retrocede", () => {
    const downloads = createDownloads();
    downloads.progress({ model: "tiny", fraction: 0.4 });
    expect(downloads.fraction("tiny")).toBeNull();
    downloads.begin("tiny");
    downloads.progress({ model: "tiny", fraction: 0.6 });
    downloads.progress({ model: "tiny", fraction: 0.5 });
    expect(downloads.fraction("tiny")).toBe(0.6);
  });

  it("al terminar desaparece, el fallo se queda hasta volver a empezar y avisa a quien mira", () => {
    const downloads = createDownloads();
    let changes = 0;
    downloads.subscribe(() => changes++);
    downloads.begin("tiny");
    downloads.end("tiny", "sin red");
    expect(downloads.fraction("tiny")).toBeNull();
    expect(downloads.failure("tiny")).toBe("sin red");
    downloads.begin("tiny");
    expect(downloads.failure("tiny")).toBeNull();
    expect(changes).toBe(3);
  });
});
