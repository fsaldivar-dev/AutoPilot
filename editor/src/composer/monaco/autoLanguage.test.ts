import { describe, expect, it } from "vitest";
import { CATALOG } from "../catalog";
import { parseAuto } from "../../domain/autoSerializer";
import {
  AUTO_THEME,
  buildCommandCompletions,
  buildElementCompletions,
  buildMonarchLanguage,
  catalogHeadWords,
  catalogSubWords,
  CONTROL_KEYWORDS,
  lineExpectsElement,
  MARKER_SEVERITY_ERROR,
  parseErrorsToMarkers,
  targetCommands,
} from "./autoLanguage";

describe("tokenizer Monarch .auto", () => {
  it("incluye el head word de los 69 comandos del catálogo", () => {
    expect(CATALOG.length).toBe(69);
    const lang = buildMonarchLanguage() as unknown as { commands: string[] };
    for (const cmd of CATALOG) {
      expect(lang.commands).toContain(cmd.name.split(" ")[0]);
    }
  });

  it("separa subcomandos que no son comandos por sí mismos", () => {
    const heads = new Set(catalogHeadWords());
    const subs = catalogSubWords();
    expect(subs).toContain("deep"); // "tree deep"
    expect(subs).toContain("enroll"); // "biometric enroll"
    for (const s of subs) expect(heads.has(s)).toBe(false);
    // "list" es head ("list buttons") y segundo token ("accounts list") —
    // debe quedar como comando, no como subcomando.
    expect(subs).not.toContain("list");
  });

  it("incluye todos los keywords de control flow", () => {
    const lang = buildMonarchLanguage() as unknown as {
      controlKeywords: string[];
      operators: string[];
    };
    for (const kw of ["if", "else", "end", "repeat", "times", "while", "until", "try", "catch", "assert", "for", "in"]) {
      expect(lang.controlKeywords).toContain(kw);
    }
    expect(CONTROL_KEYWORDS.length).toBe(12);
    for (const op of ["and", "or", "not"]) {
      expect(lang.operators).toContain(op);
    }
  });

  it("el tema define color para cada token que emite el tokenizer", () => {
    const themed = new Set(AUTO_THEME.rules.map((r) => r.token));
    for (const tok of [
      "comment",
      "keyword.control",
      "keyword.operator",
      "keyword.command",
      "type.subcommand",
      "string",
      "number",
      "variable",
      "annotation.flag",
    ]) {
      expect(themed.has(tok)).toBe(true);
    }
  });
});

describe("parseErrorsToMarkers (#176)", () => {
  it("mapea línea del parser a marker con columnas del contenido útil", () => {
    const source = "launch com.demo.app\n  repeat 3\ntap OK";
    const { errors } = parseAuto(source);
    expect(errors.length).toBeGreaterThan(0);
    const markers = parseErrorsToMarkers(errors, source);
    expect(markers[0].severity).toBe(MARKER_SEVERITY_ERROR);
    expect(markers[0].startLineNumber).toBe(2); // el `repeat 3` sin times
    expect(markers[0].endLineNumber).toBe(2);
    // squiggle bajo "repeat 3", no bajo la indentación
    expect(markers[0].startColumn).toBe(3);
    expect(markers[0].endColumn).toBe("  repeat 3".length + 1);
    expect(markers[0].message).toMatch(/repeat/);
  });

  it("el `repeat 3` sin times del QA reporta línea exacta", () => {
    const source = "repeat 3\n  tap OK\nend";
    const { errors } = parseAuto(source);
    const markers = parseErrorsToMarkers(errors, source);
    expect(markers).toHaveLength(1);
    expect(markers[0].startLineNumber).toBe(1);
    expect(markers[0].message).toContain("times");
  });

  it("clampea líneas fuera de rango del buffer", () => {
    const markers = parseErrorsToMarkers(
      [{ line: 99, message: "x" }],
      "una sola línea",
    );
    expect(markers[0].startLineNumber).toBe(1);
    expect(markers[0].endLineNumber).toBe(1);
  });

  it("línea vacía produce marker de ancho mínimo en columna 1", () => {
    const markers = parseErrorsToMarkers([{ line: 2, message: "x" }], "tap A\n\ntap B");
    expect(markers[0].startColumn).toBe(1);
    expect(markers[0].endColumn).toBe(2);
  });

  it("sin errores → sin markers (limpia squiggles previos)", () => {
    expect(parseErrorsToMarkers([], "tap OK")).toEqual([]);
  });
});

describe("completions", () => {
  it("ofrece los 69 comandos con firma como detail", () => {
    const items = buildCommandCompletions();
    expect(items).toHaveLength(69);
    const tap = items.find((i) => i.label === "tap");
    expect(tap).toBeDefined();
    expect(tap!.detail).toContain("tap");
    expect(tap!.detail).toContain("→"); // firma renderizada
    expect(tap!.documentation).toContain("Ejemplo");
  });

  it("mapea elementos del device a labels quoted", () => {
    const items = buildElementCompletions([
      { index: 1, role: "AXButton", label: "Confirmar", frame: "10,20 100x44" },
      { index: 2, role: "AXButton", label: "  ", frame: "0,0 0x0" }, // sin label — fuera
    ]);
    expect(items).toHaveLength(1);
    expect(items[0].insertText).toBe('"Confirmar"');
    expect(items[0].detail).toContain("AXButton");
  });

  it("targetCommands deriva del catálogo los comandos con param element", () => {
    const t = targetCommands();
    for (const c of ["tap", "waitFor", "waitUntilGone", "type", "scrollTo"]) {
      expect(t.has(c)).toBe(true);
    }
    expect(t.has("ping")).toBe(false);
    expect(t.has("screenshot")).toBe(false);
  });

  it("lineExpectsElement detecta cursor tras comando con target", () => {
    expect(lineExpectsElement("tap ")).toBe(true);
    expect(lineExpectsElement("  waitFor Conf")).toBe(true);
    expect(lineExpectsElement("tap")).toBe(false); // aún escribiendo el comando
    expect(lineExpectsElement("ping ")).toBe(false); // no lleva target
    expect(lineExpectsElement("")).toBe(false);
  });
});
