import { describe, expect, it } from "vitest";
import { groupByDay } from "../../src/core/libraryDays";
import { dayLabel } from "../../src/core/presentation";

const zone = "Europe/Madrid";
const now = new Date("2026-10-13T10:00:00+02:00");
const at = (id: string, createdAt: string) => ({ id, createdAt });

describe("agrupar la biblioteca por días", () => {
  it("nombra hoy y ayer y el resto con día y mes", () => {
    expect(dayLabel(new Date("2026-10-13T00:10:00+02:00"), now, zone)).toBe("Hoy");
    expect(dayLabel(new Date("2026-10-12T23:50:00+02:00"), now, zone)).toBe("Ayer");
    expect(dayLabel(new Date("2026-10-09T09:00:00+02:00"), now, zone)).toBe("9 de octubre");
  });
  it("añade el año cuando no es el actual", () => {
    expect(dayLabel(new Date("2025-12-31T23:59:00+01:00"), now, zone)).toBe("31 de diciembre de 2025");
  });
  it("corta el día por la zona horaria, no por UTC", () => {
    expect(dayLabel(new Date("2026-10-12T22:30:00Z"), now, zone)).toBe("Hoy");
  });
  it("agrupa tramos contiguos conservando el orden", () => {
    const groups = groupByDay([at("a", "2026-10-13T09:00:00+02:00"), at("b", "2026-10-13T08:00:00+02:00"), at("c", "2026-10-12T20:00:00+02:00"), at("d", "2026-10-09T20:00:00+02:00")], now, zone);
    expect(groups.map((group) => [group.heading, group.items.map((item) => item.id)])).toEqual([
      ["Hoy", ["a", "b"]],
      ["Ayer", ["c"]],
      ["9 de octubre", ["d"]],
    ]);
    expect(groups.map((group) => group.key)).toEqual(["2026-10-13", "2026-10-12", "2026-10-09"]);
  });
  it("no devuelve grupos sin elementos", () => {
    expect(groupByDay([], now, zone)).toEqual([]);
  });
});
