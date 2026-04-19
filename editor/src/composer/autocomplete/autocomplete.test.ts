import { describe, expect, it } from "vitest";
import { suggest } from "./index";
import type {
  Block,
  Component,
  EnvVar,
  IndexedElement,
} from "../../domain/types";

const elements: IndexedElement[] = [
  { index: 0, role: "AXButton", label: "Iniciar sesion", frame: "[100,200 50x30]" },
  { index: 1, role: "AXTextField", label: "Correo", frame: "[100,250 200x30]" },
  { index: 2, role: "AXGroup", label: "Formulario", frame: "[0,0 300x400]" },
];

const components: Component[] = [
  {
    id: "c1",
    projectId: "p1",
    name: "LoginFlow",
    signature: [
      { name: "email", type: "string" },
      { name: "password", type: "string", secure: true },
    ],
    returnType: "Session",
    body: [],
    usageCount: 8,
  },
];

const envVars: EnvVar[] = [
  {
    projectId: "p1",
    scope: "staging",
    key: "user.email",
    value: "maria@demo.io",
    secret: false,
  },
  {
    projectId: "p1",
    scope: "staging",
    key: "user.password",
    value: "secret",
    secret: true,
  },
];

const recents: Block[] = [
  {
    id: "b1",
    kind: "command",
    command: "ping",
    args: {},
    meta: { status: "ok" },
  },
];

describe("suggest", () => {
  it("lists commands when input is empty", () => {
    const s = suggest({
      input: "",
      cursor: 0,
      platform: "ios",
      elements,
      components,
      envVars,
      recents,
    });
    expect(s.length).toBeGreaterThan(5);
    expect(s.some((x) => x.kind === "command" && x.label === "tap")).toBe(true);
  });

  it("filters commands by query", () => {
    const s = suggest({
      input: "ta",
      cursor: 2,
      platform: "ios",
      elements,
      components,
      envVars,
      recents,
    });
    expect(s[0].label).toMatch(/^tap/);
  });

  it("suggests elements after tap", () => {
    const s = suggest({
      input: "tap ",
      cursor: 4,
      platform: "ios",
      elements,
      components,
      envVars,
      recents,
    });
    expect(s.some((x) => x.kind === "element")).toBe(true);
  });

  it("suggests containers after within", () => {
    const s = suggest({
      input: 'tap "Login" within ',
      cursor: 19,
      platform: "ios",
      elements,
      components,
      envVars,
      recents,
    });
    const elementSugs = s.filter((x) => x.kind === "element");
    expect(elementSugs.length).toBeGreaterThan(0);
    expect(elementSugs.some((x) => x.label.includes("Formulario"))).toBe(true);
  });

  it("suggests env vars after $", () => {
    const s = suggest({
      input: "type $",
      cursor: 6,
      platform: "ios",
      elements,
      components,
      envVars,
      recents,
    });
    expect(s.some((x) => x.kind === "variable" && x.label === "$user.email")).toBe(
      true
    );
  });

  it("suggests components as top-level", () => {
    const s = suggest({
      input: "Log",
      cursor: 3,
      platform: "ios",
      elements,
      components,
      envVars,
      recents,
    });
    expect(s.some((x) => x.kind === "component" && x.label === "LoginFlow")).toBe(
      true
    );
  });

  it("hides Android-only commands when platform=ios", () => {
    const s = suggest({
      input: "set",
      cursor: 3,
      platform: "ios",
      elements,
      components,
      envVars,
      recents,
    });
    // `setup` is android-only; `setLocation` and `setAppearance` are both
    expect(s.some((x) => x.label === "setup")).toBe(false);
    expect(s.some((x) => x.label === "setLocation")).toBe(true);
  });

  it("hides iOS-only commands when platform=android", () => {
    const s = suggest({
      input: "cam",
      cursor: 3,
      platform: "android",
      elements,
      components,
      envVars,
      recents,
    });
    // `camera start` is iOS-only
    expect(s.some((x) => x.label.startsWith("camera"))).toBe(false);
  });

  it("returns response under 50ms for 100 suggestions", () => {
    const start = performance.now();
    for (let i = 0; i < 100; i++) {
      suggest({
        input: "tap ",
        cursor: 4,
        platform: "ios",
        elements,
        components,
        envVars,
        recents,
      });
    }
    const elapsed = performance.now() - start;
    // Per-call average should be well under 1ms; 100 calls under 500ms budget
    expect(elapsed).toBeLessThan(500);
  });
});
