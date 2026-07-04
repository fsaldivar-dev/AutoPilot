import { describe, expect, it } from "vitest";
import { CATALOG } from "../catalog";
import { parseAuto } from "../../domain/autoSerializer";
import {
  AUTO_THEME,
  buildMonarchLanguage,
  catalogHeadWords,
  catalogSubWords,
  CONTROL_KEYWORDS,
  logicSnippets,
  MARKER_SEVERITY_ERROR,
  openBlockStack,
  parseErrorsToMarkers,
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

// #186 — capa estructural de la vista Código.
describe("openBlockStack", () => {
  it("sin bloques abiertos → pila vacía", () => {
    expect(openBlockStack([])).toEqual([]);
    expect(openBlockStack(["tap OK", "ping"])).toEqual([]);
  });

  it("if abierto queda en la pila", () => {
    expect(openBlockStack(['if platform == "ios"', "  tap OK"])).toEqual(["if"]);
  });

  it("end cierra el bloque más interno", () => {
    expect(openBlockStack(["if x", "  tap A", "end"])).toEqual([]);
    expect(openBlockStack(["repeat 3 times", "  if x", "  end"])).toEqual(["repeat"]);
  });

  it("anidamiento: el tope es el bloque más interno", () => {
    const stack = openBlockStack(["repeat 3 times", "  try", "    tap A"]);
    expect(stack).toEqual(["repeat", "try"]);
  });

  it("ignora comentarios y líneas vacías", () => {
    expect(openBlockStack(["# if comentado", "", "if x"])).toEqual(["if"]);
  });
});

describe("logicSnippets", () => {
  it("sin bloque abierto NO ofrece end/else/catch", () => {
    const labels = logicSnippets(undefined).map((s) => s.label);
    expect(labels).not.toContain("end");
    expect(labels).not.toContain("else");
    expect(labels).not.toContain("catch");
    expect(labels).toContain("if");
    expect(labels).toContain("repeat");
    expect(labels).toContain("try");
  });

  it("con if abierto ofrece end y else como closers", () => {
    const snips = logicSnippets("if");
    const end = snips.find((s) => s.label === "end");
    const else_ = snips.find((s) => s.label === "else");
    expect(end?.closer).toBe(true);
    expect(else_?.closer).toBe(true);
    expect(snips.find((s) => s.label === "catch")).toBeUndefined();
  });

  it("catch solo dentro de try; repeat abierto solo ofrece end", () => {
    expect(logicSnippets("try").some((s) => s.label === "catch")).toBe(true);
    const rep = logicSnippets("repeat");
    expect(rep.some((s) => s.label === "end")).toBe(true);
    expect(rep.some((s) => s.label === "else")).toBe(false);
    expect(rep.some((s) => s.label === "catch")).toBe(false);
  });

  it("los snippets de bloque cierran con end y usan placeholders de Monaco", () => {
    for (const label of ["if", "repeat", "try"]) {
      const s = logicSnippets(undefined).find((x) => x.label === label)!;
      expect(s.insertText).toMatch(/\nend$/);
      expect(s.insertText).toContain("$");
    }
  });
});
