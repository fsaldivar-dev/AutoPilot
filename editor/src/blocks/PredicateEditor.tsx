import { useEffect, useRef, useState } from "react";
import { predicateToText, parsePredicate } from "../composer/predicateText";
import { tokenizeLine } from "../domain/autoTokenize";
import type { Predicate } from "../domain/types";

interface Props {
  value: Predicate;
  placeholder?: string;
  onChange: (p: Predicate) => void;
  autoFocus?: boolean;
  onBlur?: () => void;
}

// PredicateEditor — input inline que edita un `Predicate`.
// - Parsea en vivo mientras se tipea. Si hay error de sintaxis, el borde se
//   pone coral y no se emite onChange hasta que vuelva a ser válido.
// - onBlur solo se dispara si el texto parsea OK (evita persistir basura).
// - Autocomplete se cablea en Fase 1.2.3 (PredicateProvider).
export function PredicateEditor({ value, placeholder, onChange, autoFocus, onBlur }: Props) {
  const [text, setText] = useState(() => predicateToText(value));
  const [error, setError] = useState<string | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);
  const lastEmittedRef = useRef<Predicate>(value);

  // Mantener sync cuando value cambia externamente (ej: otro componente
  // muta el store), pero solo si el usuario no está editando activamente.
  useEffect(() => {
    const serialized = predicateToText(value);
    if (lastEmittedRef.current !== value && serialized !== text) {
      setText(serialized);
      setError(null);
    }
    lastEmittedRef.current = value;
  }, [value]);

  useEffect(() => {
    if (autoFocus) inputRef.current?.focus();
  }, [autoFocus]);

  function tryParse(newText: string) {
    const tokens = tokenizeLine(newText);
    if (tokens.length === 0) {
      setError("vacío");
      return;
    }
    try {
      const pred = parsePredicate(tokens, 0);
      setError(null);
      lastEmittedRef.current = pred;
      onChange(pred);
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }

  return (
    <span className={`predicate-editor${error ? " has-error" : ""}`} data-testid="predicate-editor">
      <input
        ref={inputRef}
        className="predicate-input"
        type="text"
        value={text}
        placeholder={placeholder ?? 'exists "..."'}
        onChange={(e) => {
          const v = e.target.value;
          setText(v);
          tryParse(v);
        }}
        onBlur={() => {
          if (!error) onBlur?.();
        }}
        autoComplete="off"
        spellCheck={false}
        title={error ?? undefined}
      />
    </span>
  );
}
