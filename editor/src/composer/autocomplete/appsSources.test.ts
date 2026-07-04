import { describe, expect, it } from "vitest";
import { appSuggestionSources, parseAppsOutput } from "./appsSources";

// #187 — fuentes de bundleId para el predictivo.
describe("parseAppsOutput", () => {
  it("parsea líneas bundleId<TAB>nombre", () => {
    const out = "com.a.uno\tUno\ncom.b.dos\tDos App\n";
    expect(parseAppsOutput(out)).toEqual([
      { bundle: "com.a.uno", name: "Uno" },
      { bundle: "com.b.dos", name: "Dos App" },
    ]);
  });

  it("ignora líneas sin tab (mensajes del CLI, vacías)", () => {
    const out = "(sin apps de usuario — usa `apps --all`)\n\ncom.x\tX\n";
    expect(parseAppsOutput(out)).toEqual([{ bundle: "com.x", name: "X" }]);
  });

  it("nombre vacío cae al bundle", () => {
    expect(parseAppsOutput("com.x\t\n")).toEqual([{ bundle: "com.x", name: "com.x" }]);
  });
});

describe("appSuggestionSources", () => {
  const installed = [
    { bundle: "com.sajaru.explorea", name: "Explorea" },
    { bundle: "com.otro.app", name: "Otra" },
  ];

  it("orden: proyecto → en pantalla → instaladas, sin duplicados", () => {
    const s = appSuggestionSources(
      { name: "Demo", bundleId: "com.sajaru.explorea" },
      { name: "Explorea", bundle: "com.sajaru.explorea" },
      installed
    );
    // El bundle del proyecto absorbe el duplicado de pantalla e instaladas.
    expect(s).toEqual([
      { bundle: "com.sajaru.explorea", name: "Demo", source: "proyecto" },
      { bundle: "com.otro.app", name: "Otra", source: "instalada" },
    ]);
  });

  it("sin proyecto ní detectedApp → solo instaladas", () => {
    const s = appSuggestionSources(undefined, null, installed);
    expect(s).toHaveLength(2);
    expect(s.every((x) => x.source === "instalada")).toBe(true);
  });
});
