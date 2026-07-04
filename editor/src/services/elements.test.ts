import { describe, expect, it } from "vitest";
import { parseTreeOutput } from "./elements";

// #189 — parser del output de `tree` (printElement del CLI, iOS y Android).
describe("parseTreeOutput", () => {
  it("parsea botones y textos con label", () => {
    const out = [
      "AXWindow  [0,0 402x874]",
      "  AXGroup  [0,0 402x874]",
      '    AXButton  label="Desbloquear con biometría"  [24,700 354x48]',
      '    AXStaticText  "Mis Viajes"  [20,60 200x30]',
      '    AXButton  "Inicio"  [8,789 74x38]',
    ].join("\n");
    const els = parseTreeOutput(out);
    expect(els.map((e) => e.label)).toEqual([
      "Desbloquear con biometría",
      "Mis Viajes",
      "Inicio",
    ]);
    expect(els[0].role).toBe("Button");
    expect(els[0].frame).toBe("[24,700 354x48]");
    expect(els[1].role).toBe("StaticText");
  });

  it("excluye contenedores sin label (Window/Group)", () => {
    const out = "AXWindow  [0,0 402x874]\n  AXGroup  [0,0 402x874]\n";
    expect(parseTreeOutput(out)).toEqual([]);
  });

  it("StaticText sin label queda fuera; TextField sin label entra por id", () => {
    const out = [
      "  AXStaticText  [0,0 10x10]",
      "  AXTextField  id=email_field  [10,10 200x40]",
    ].join("\n");
    const els = parseTreeOutput(out);
    expect(els).toHaveLength(1);
    expect(els[0].role).toBe("TextField");
    expect(els[0].label).toBe("email_field");
  });

  it("title y label distintos → gana label (formato printElement)", () => {
    const out = '  AXButton  "Titulo"  label="Etiqueta"  [1,2 3x4]';
    const els = parseTreeOutput(out);
    expect(els[0].label).toBe("Etiqueta");
  });

  it("output sin matches → lista vacía (no rompe el store)", () => {
    expect(parseTreeOutput("")).toEqual([]);
    expect(parseTreeOutput("error: no booted device")).toEqual([]);
  });
});
