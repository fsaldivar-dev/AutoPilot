import { describe, expect, it } from "vitest";
import { assetKey } from "./assets";

// #194 — el slug del asset debe matchear la regex de substituteVars.
describe("assetKey", () => {
  it("quita extensión y normaliza a [A-Za-z0-9_.]", () => {
    expect(assetKey("foto-1.jpg")).toBe("foto_1");
    expect(assetKey("ocr test (2).png")).toBe("ocr_test__2_");
    expect(assetKey("logo.final.png")).toBe("logo.final");
  });

  it("prefija _ si empieza con dígito", () => {
    expect(assetKey("1a.png")).toBe("_1a");
  });
});
