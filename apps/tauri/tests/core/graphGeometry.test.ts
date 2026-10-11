import { expect, test } from "vitest";
import { fitGraph, hitRoute, zoomScale } from "../../src/core/graphGeometry";
import type { RoutedEdge } from "../../src/core/graphScene";

const route: RoutedEdge = { points: [{ x: 0, y: 0 }, { x: 0, y: 180 }, { x: 200, y: 180 }], label: { x: 30, y: 130, width: 150, height: 26, text: "Asignado a persona" } };

test("alejar un mapa encuadrado por debajo del mínimo no aumenta su escala", () => {
  const { scale } = fitGraph({ x: 0, y: 0, width: 8000, height: 6000 }, 400, 300);
  expect(zoomScale(scale, 1 / 1.2)).toBeLessThanOrEqual(scale);
  expect(zoomScale(scale, 1.2)).toBeGreaterThan(scale);
  expect(zoomScale(.2, .1)).toBe(.12);
  expect(zoomScale(2, 2)).toBe(2.5);
});

test("selecciona toda la etiqueta y cada tramo visible de la conexión", () => {
  expect(hitRoute(route, { x: 175, y: 145 }, 4)).toBe(true);
  expect(hitRoute(route, { x: 3, y: 90 }, 4)).toBe(true);
  expect(hitRoute(route, { x: 100, y: 177 }, 4)).toBe(true);
  expect(hitRoute(route, { x: 100, y: 90 }, 4)).toBe(false);
});

test("encuadra todas las entidades, rutas y etiquetas al entrar el inspector", () => {
  const bounds = { x: -120, y: -80, width: 1400, height: 900 };
  for (const width of [1050, 798, 380]) {
    const camera = fitGraph(bounds, width, 530);
    expect(bounds.x * camera.scale + camera.x).toBeGreaterThanOrEqual(43.9);
    expect((bounds.x + bounds.width) * camera.scale + camera.x).toBeLessThanOrEqual(width - 43.9);
    expect(bounds.y * camera.scale + camera.y).toBeGreaterThanOrEqual(43.9);
    expect((bounds.y + bounds.height) * camera.scale + camera.y).toBeLessThanOrEqual(530 - 43.9);
  }
});

test("los mapas grandes también caben completos en una ventana pequeña", () => {
  const camera = fitGraph({ x: 0, y: 0, width: 8000, height: 6000 }, 400, 300);
  expect(camera.scale * 8000).toBeLessThanOrEqual(400 - 88);
  expect(camera.scale * 6000).toBeLessThanOrEqual(300 - 88);
  expect(fitGraph({ x: 0, y: 0, width: 0, height: 0 }, 0, 0)).toEqual({ x: 0, y: 0, scale: 1 });
});
