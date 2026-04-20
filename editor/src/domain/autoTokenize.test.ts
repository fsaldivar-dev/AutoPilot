import { describe, expect, it } from "vitest";
import { tokenizeLine } from "./autoTokenize";

describe("autoTokenize.tokenizeLine", () => {
  it("splits whitespace", () => {
    expect(tokenizeLine("tap Login")).toEqual(["tap", "Login"]);
  });

  it("preserves double-quoted strings with spaces", () => {
    expect(tokenizeLine('tap "Sign In"')).toEqual(["tap", "Sign In"]);
  });

  it("preserves single-quoted strings", () => {
    expect(tokenizeLine("type 'Hello World'")).toEqual(["type", "Hello World"]);
  });

  it("handles empty string", () => {
    expect(tokenizeLine("")).toEqual([]);
  });

  it("handles multiple quoted segments", () => {
    expect(tokenizeLine('hasText "Greeting" "Hola"'))
      .toEqual(["hasText", "Greeting", "Hola"]);
  });

  it("keeps bracket syntax as one token", () => {
    expect(tokenizeLine('tap[button] "Login"'))
      .toEqual(["tap[button]", "Login"]);
  });
});
