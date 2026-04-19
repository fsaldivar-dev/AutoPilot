import { describe, expect, it } from "vitest";
import { detectParams } from "./GroupAsComponentModal";
import type { Block } from "../domain/types";

describe("detectParams", () => {
  it("extracts $variables from command text", () => {
    const blocks: Block[] = [
      { id: "b1", kind: "command", command: 'tap "Login"', args: {}, meta: { status: "ok" } },
      {
        id: "b2",
        kind: "command",
        command: "type $user.email",
        args: {},
        meta: { status: "ok" },
      },
      {
        id: "b3",
        kind: "command",
        command: "type $user.password",
        args: {},
        meta: { status: "ok" },
      },
    ];
    const params = detectParams(blocks);
    expect(params.map((p) => p.name).sort()).toEqual([
      "user.email",
      "user.password",
    ]);
    const secret = params.find((p) => p.name === "user.password");
    expect(secret?.secure).toBe(true);
  });

  it("returns empty when no variables", () => {
    const blocks: Block[] = [
      { id: "b1", kind: "command", command: 'tap "Login"', args: {}, meta: { status: "ok" } },
    ];
    expect(detectParams(blocks)).toHaveLength(0);
  });

  it("scans args values too", () => {
    const blocks: Block[] = [
      {
        id: "b1",
        kind: "command",
        command: "type",
        args: { value: "$apiKey" },
        meta: { status: "ok" },
      },
    ];
    const params = detectParams(blocks);
    expect(params.map((p) => p.name)).toEqual(["apiKey"]);
    expect(params[0].secure).toBe(true);
  });
});
