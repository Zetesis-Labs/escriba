import { expect, test } from "vitest";
import { isLocalSttId, localModel, localSttId, validModel } from "../../src/runtime/localModels";

test("el Whisper de serie usa el modelo de los ajustes y cada añadido el suyo", () => {
  expect(localModel({ id: "local-stt", model: "viejo" }, "large-v3-turbo")).toBe("large-v3-turbo");
  expect(localModel({ id: "local-stt-base", model: "base" }, "large-v3-turbo")).toBe("base");
  expect(localModel({ id: "local-stt", model: "x" }, undefined)).toBeNull();
});

test("un modelo añadido se identifica por su nombre, sin rutas", () => {
  expect(localSttId("base.en")).toBe("local-stt-base.en");
  expect(isLocalSttId("local-stt")).toBe(true);
  expect(isLocalSttId("local-stt-base")).toBe(true);
  expect(isLocalSttId("remote-stt")).toBe(false);
  expect(isLocalSttId("local-stt-")).toBe(false);
  expect(validModel("large-v3-turbo")).toBe(true);
  expect(validModel("../fuera")).toBe(false);
  expect(validModel("a/b")).toBe(false);
  expect(validModel("")).toBe(false);
});
