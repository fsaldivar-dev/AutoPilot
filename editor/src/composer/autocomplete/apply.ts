// Aplica una sugerencia del popover sobre el input, reemplazando el rango
// correcto. Compartido por CommandBar e InlineCommandEditor (#183) — antes
// cada uno duplicaba esta lógica y ambos reemplazaban solo el último token,
// así que aceptar un comando multi-palabra («biometric enroll») con parte ya
// tipeada («biometric enro») duplicaba el prefijo: «biometric biometric
// enroll». Y como pick nunca era idempotente, el check "sugerencia ya
// aplicada → ejecutar" (#180) jamás se cumplía: Enter completaba en loop y el
// comando no se insertaba nunca.

export interface AppliedSuggestion {
  value: string;
  cursor: number;
}

export function applySuggestion(
  value: string,
  cursor: number,
  insertText: string
): AppliedSuggestion {
  const prefix = value.slice(0, cursor);
  const suffix = value.slice(cursor);
  const tokenStart = Math.max(
    prefix.lastIndexOf(" "),
    prefix.lastIndexOf("\t"),
    prefix.lastIndexOf("\n"),
    prefix.lastIndexOf("["),
    prefix.lastIndexOf("\""),
    prefix.lastIndexOf("$") - 1
  );
  // Para $var el reemplazo incluye el $ mismo.
  let from = insertText.startsWith("$")
    ? Math.min(prefix.lastIndexOf("$"), prefix.length)
    : tokenStart + 1;

  // Extiende el reemplazo hacia la izquierda si el texto previo al token
  // (alineado a borde de palabra) ya es prefijo del insertText — evita
  // duplicar las palabras ya tipeadas de un comando multi-palabra o la
  // comilla de apertura de un elemento citado.
  if (!insertText.startsWith("$")) {
    const target = insertText.toLowerCase();
    for (let i = 0; i < from; i++) {
      if (i > 0 && !/\s/.test(value[i - 1])) continue;
      if (target.startsWith(value.slice(i, from).toLowerCase())) {
        from = i;
        break;
      }
    }
  }

  const newValue = value.slice(0, from) + insertText + suffix;
  return { value: newValue, cursor: from + insertText.length };
}
