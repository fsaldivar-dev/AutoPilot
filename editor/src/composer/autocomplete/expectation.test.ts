import { describe, expect, it } from "vitest";
import { expectationAt, signatureHelpAt } from "./expectation";

// #185 — el motor de expectativa deriva del catálogo qué token va en la
// posición del cursor. Es la fuente de verdad del predictivo en Bloques y
// Código.
describe("expectationAt", () => {
  const at = (line: string, cursor = line.length) =>
    expectationAt(line, cursor, "ios");

  it("línea vacía o primer token → command", () => {
    expect(at("").kind).toBe("command");
    expect(at("ta").kind).toBe("command");
    expect(at("launch").kind).toBe("command");
  });

  it("comando multi-palabra a medias sigue siendo command", () => {
    expect(at("biometric enr").kind).toBe("command");
    expect(at("tree d").kind).toBe("command");
    expect(at("biometric ").kind).toBe("command");
  });

  it("tap → param element", () => {
    const e = at("tap ");
    expect(e.kind).toBe("param");
    if (e.kind === "param") {
      expect(e.param.type).toBe("element");
      expect(e.paramIndex).toBe(0);
    }
  });

  it("tap con quote abierta sigue en el param 0", () => {
    const e = at('tap "Inic');
    expect(e.kind).toBe("param");
    if (e.kind === "param") expect(e.paramIndex).toBe(0);
  });

  it("launch → param string (bundleId), NO command", () => {
    const e = at("launch ");
    expect(e.kind).toBe("param");
    if (e.kind === "param") {
      expect(e.param.type).toBe("string");
      expect(e.param.name).toBe("bundleId");
    }
  });

  it("scroll target → segundo param enum con sus valores", () => {
    const e = at('scroll "Lista" ');
    expect(e.kind).toBe("param");
    if (e.kind === "param") {
      expect(e.param.type).toBe("enum");
      expect(e.param.enumValues).toContain("down");
      expect(e.paramIndex).toBe(1);
    }
  });

  it("waitFor label → segundo param number", () => {
    const e = at('waitFor "Home" ');
    expect(e.kind).toBe("param");
    if (e.kind === "param") expect(e.param.type).toBe("number");
  });

  it("después del último param declarado → rest", () => {
    expect(at('waitFor "Home" 5 ').kind).toBe("rest");
    expect(at("ping ").kind).toBe("rest");
  });

  it("$ → variable", () => {
    expect(at("type $US").kind).toBe("variable");
    expect(at("type $").kind).toBe("variable");
  });

  it("if / assert / repeat while → predicate", () => {
    expect(at("if ").kind).toBe("predicate");
    expect(at('if exists "x" and ').kind).toBe("predicate");
    expect(at("assert ").kind).toBe("predicate");
    expect(at("repeat while ").kind).toBe("predicate");
    expect(at("repeat until ").kind).toBe("predicate");
  });

  it("repeat sin while/until no es predicado", () => {
    expect(at("repeat 3 ").kind).toBe("rest");
  });

  it("comandos multi-palabra resuelven al nombre más largo", () => {
    const e = at("tree deep ");
    expect(e.kind).toBe("rest");
    const e2 = at('list buttons ');
    expect(e2.kind).toBe("rest");
  });

  it("head desconocido con args → rest (no ofrecer comandos a mitad de línea)", () => {
    expect(at("foo bar ").kind).toBe("rest");
  });

  it("plataforma filtra: comando android-only no matchea en ios", () => {
    const e = expectationAt("boot ", 5, "android");
    expect(e.kind).toBe("command");
  });
});

describe("signatureHelpAt", () => {
  it("marca el parámetro activo", () => {
    const s = signatureHelpAt('scroll "Lista" ', 15, "ios");
    expect(s).not.toBeNull();
    expect(s!.name).toBe("scroll");
    expect(s!.pre).toBe("target");
    expect(s!.active).toBe("direction");
  });

  it("param opcional con default se renderiza [timeout=10]", () => {
    const s = signatureHelpAt('waitFor "Home" ', 15, "ios");
    expect(s!.active).toBe("[timeout=10]");
  });

  it("null cuando no hay comando activo o no tiene params", () => {
    expect(signatureHelpAt("ta", 2, "ios")).toBeNull();
    expect(signatureHelpAt("ping ", 5, "ios")).toBeNull();
  });
});
