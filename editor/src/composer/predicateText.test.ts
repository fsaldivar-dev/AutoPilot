import { describe, expect, it } from "vitest";
import type { Predicate } from "../domain/types";
import { predicateToText, parsePredicate } from "./predicateText";

describe("predicateText", () => {
  describe("predicateToText", () => {
    it("simple call with quoted arg", () => {
      const p: Predicate = { kind: "call", name: "exists", args: ["Login"] };
      expect(predicateToText(p)).toBe('exists "Login"');
    });

    it("call with keyword-style args (platform is ios)", () => {
      const p: Predicate = { kind: "call", name: "platform", args: ["is", "ios"] };
      expect(predicateToText(p)).toBe("platform is ios");
    });

    it("call with $variable is not quoted", () => {
      const p: Predicate = { kind: "call", name: "visible", args: ["$btn"] };
      expect(predicateToText(p)).toBe("visible $btn");
    });

    it("and composition", () => {
      const p: Predicate = {
        kind: "and",
        left: { kind: "call", name: "exists", args: ["A"] },
        right: { kind: "call", name: "visible", args: ["B"] },
      };
      expect(predicateToText(p)).toBe('exists "A" and visible "B"');
    });

    it("or composition", () => {
      const p: Predicate = {
        kind: "or",
        left: { kind: "call", name: "exists", args: ["A"] },
        right: { kind: "call", name: "exists", args: ["B"] },
      };
      expect(predicateToText(p)).toBe('exists "A" or exists "B"');
    });

    it("not unary", () => {
      const p: Predicate = {
        kind: "not",
        inner: { kind: "call", name: "exists", args: ["Error"] },
      };
      expect(predicateToText(p)).toBe('not exists "Error"');
    });
  });

  describe("parsePredicate", () => {
    it("simple call", () => {
      const p = parsePredicate(["exists", "Login"], 1);
      expect(p).toEqual({ kind: "call", name: "exists", args: ["Login"] });
    });

    it("platform is ios", () => {
      const p = parsePredicate(["platform", "is", "ios"], 1);
      expect(p).toEqual({ kind: "call", name: "platform", args: ["is", "ios"] });
    });

    it("and chain", () => {
      const p = parsePredicate(["exists", "A", "and", "visible", "B"], 1);
      expect(p).toEqual({
        kind: "and",
        left: { kind: "call", name: "exists", args: ["A"] },
        right: { kind: "call", name: "visible", args: ["B"] },
      });
    });

    it("or with lower precedence than and", () => {
      // exists A and exists B or exists C == (A and B) or C
      const p = parsePredicate(["exists", "A", "and", "exists", "B", "or", "exists", "C"], 1);
      expect(p).toEqual({
        kind: "or",
        left: {
          kind: "and",
          left: { kind: "call", name: "exists", args: ["A"] },
          right: { kind: "call", name: "exists", args: ["B"] },
        },
        right: { kind: "call", name: "exists", args: ["C"] },
      });
    });

    it("not higher precedence than and", () => {
      const p = parsePredicate(["not", "exists", "Error", "and", "visible", "A"], 1);
      expect(p).toEqual({
        kind: "and",
        left: { kind: "not", inner: { kind: "call", name: "exists", args: ["Error"] } },
        right: { kind: "call", name: "visible", args: ["A"] },
      });
    });

    it("parentheses override precedence", () => {
      // (exists A or exists B) and visible C
      const p = parsePredicate([
        "(", "exists", "A", "or", "exists", "B", ")",
        "and", "visible", "C",
      ], 1);
      expect(p).toEqual({
        kind: "and",
        left: {
          kind: "or",
          left: { kind: "call", name: "exists", args: ["A"] },
          right: { kind: "call", name: "exists", args: ["B"] },
        },
        right: { kind: "call", name: "visible", args: ["C"] },
      });
    });

    it("throws on missing close paren", () => {
      expect(() => parsePredicate(["(", "exists", "A"], 1)).toThrow();
    });

    it("throws on empty", () => {
      expect(() => parsePredicate([], 1)).toThrow();
    });
  });

  describe("roundtrip", () => {
    const cases: { text: string; pred: Predicate }[] = [
      {
        text: 'exists "Login"',
        pred: { kind: "call", name: "exists", args: ["Login"] },
      },
      {
        text: "platform is ios",
        pred: { kind: "call", name: "platform", args: ["is", "ios"] },
      },
      {
        text: 'not exists "Error"',
        pred: { kind: "not", inner: { kind: "call", name: "exists", args: ["Error"] } },
      },
      {
        text: 'exists "A" and visible "B"',
        pred: {
          kind: "and",
          left: { kind: "call", name: "exists", args: ["A"] },
          right: { kind: "call", name: "visible", args: ["B"] },
        },
      },
    ];

    for (const { text, pred } of cases) {
      it(`round-trips: ${text}`, async () => {
        const { tokenizeLine } = await import("../domain/autoTokenize");
        const tokens = tokenizeLine(text);
        const parsed = parsePredicate(tokens, 1);
        expect(parsed).toEqual(pred);
        expect(predicateToText(parsed)).toBe(text);
      });
    }
  });
});
