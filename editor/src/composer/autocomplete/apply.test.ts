import { describe, expect, it } from "vitest";
import { applySuggestion } from "./apply";

// #183 — aceptar una sugerencia multi-palabra no debe duplicar las palabras
// ya tipeadas, y aplicar la misma sugerencia dos veces debe ser idempotente
// (el check "sugerencia ya aplicada → ejecutar" de #180 depende de eso).
describe("applySuggestion", () => {
  it("token simple: reemplaza el token con el insertText", () => {
    const r = applySuggestion("ta", 2, "tap ");
    expect(r.value).toBe("tap ");
    expect(r.cursor).toBe(4);
  });

  it("comando multi-palabra: NO duplica el prefijo ya tipeado (#183)", () => {
    const r = applySuggestion("biometric enro", 14, "biometric enroll");
    expect(r.value).toBe("biometric enroll");
    expect(r.cursor).toBe(16);
  });

  it("es idempotente: aplicar sobre el valor ya completo es no-op", () => {
    const once = applySuggestion("biometric enro", 14, "biometric enroll");
    const twice = applySuggestion(once.value, once.cursor, "biometric enroll");
    expect(twice.value).toBe(once.value);
  });

  it("multi-palabra con solo la primera palabra tipeada", () => {
    const r = applySuggestion("tree d", 6, "tree deep");
    expect(r.value).toBe("tree deep");
  });

  it("elemento citado: no duplica la comilla de apertura", () => {
    const r = applySuggestion('tap "Iniciar ses', 16, '"Iniciar sesion"');
    expect(r.value).toBe('tap "Iniciar sesion"');
  });

  it("no toca el texto previo cuando no hay overlap", () => {
    const r = applySuggestion('tap "Log', 8, '"Login"');
    expect(r.value).toBe('tap "Login"');
  });

  it("$var reemplaza incluyendo el sigilo", () => {
    const r = applySuggestion("type $US", 8, "$USER");
    expect(r.value).toBe("type $USER");
    expect(r.cursor).toBe(10);
  });

  it("el overlap solo se extiende en bordes de palabra", () => {
    // "xbiometric" no es prefijo de "biometric enroll" alineado a palabra:
    // el token «enro» se reemplaza pero «xbiometric» queda intacto.
    const r = applySuggestion("xbiometric enro", 15, "biometric enroll");
    expect(r.value).toBe("xbiometric biometric enroll");
  });

  it("respeta el sufijo después del cursor", () => {
    const r = applySuggestion("biometric enro --fast", 14, "biometric enroll");
    expect(r.value).toBe("biometric enroll --fast");
  });
});
