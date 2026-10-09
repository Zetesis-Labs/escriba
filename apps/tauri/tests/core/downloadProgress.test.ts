import { describe, expect, it } from "vitest";
import { progressForModel } from "../../src/core/downloadProgress";

describe("progreso de descarga del modelo", () => {
  it("acepta solo fracciones válidas del modelo solicitado", () => {
    expect(progressForModel({ model: "large-v3", fraction: 0.4 }, "large-v3")).toBe(0.4);
    expect(progressForModel({ model: "small", fraction: 0.8 }, "large-v3")).toBeNull();
    expect(progressForModel({ model: "large-v3", fraction: 2 }, "large-v3")).toBeNull();
    expect(progressForModel({ model: "large-v3", fraction: Number.NaN }, "large-v3")).toBeNull();
  });
});
