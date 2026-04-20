import { describe, expect, it } from "vitest";
import { tokenize } from "./tokenize";

describe("tokenize", () => {
  it("empty input", () => {
    const c = tokenize("", 0);
    expect(c.token).toBe("");
    expect(c.commandWord).toBeUndefined();
    expect(c.insideBrackets).toBe(false);
    expect(c.afterWithin).toBe(false);
    expect(c.afterDollar).toBe(false);
  });

  it("partial command", () => {
    const c = tokenize("ta", 2);
    expect(c.token).toBe("ta");
    expect(c.commandWord).toBe("ta");
  });

  it("after action keyword with space", () => {
    const c = tokenize("tap ", 4);
    expect(c.commandWord).toBe("tap");
    expect(c.paramIndex).toBe(1);
  });

  it("detects insideBrackets", () => {
    const c = tokenize("tap[but", 7);
    expect(c.insideBrackets).toBe(true);
  });

  it("detects afterWithin", () => {
    const c = tokenize('tap "Login" within ', 19);
    expect(c.afterWithin).toBe(true);
  });

  it("detects afterDollar", () => {
    const c = tokenize("type $us", 8);
    expect(c.afterDollar).toBe(true);
  });

  it("quoted argument closes token", () => {
    const c = tokenize('tap "Login"', 11);
    // cursor is right after the closing quote; token starts after last `"`
    expect(c.commandWord).toBe("tap");
  });
});
