import Editor, { type OnMount } from "@monaco-editor/react";
import { useEffect, useMemo, useRef, useState } from "react";
import { selectCurrentFlow, useStore } from "../state/store";
import { parseAuto, serializeFlow } from "../domain/autoSerializer";
import { ensureMonacoSetup, monaco } from "./monaco/setupMonaco";
import {
  AUTO_LANGUAGE_ID,
  AUTO_THEME_ID,
  parseErrorsToMarkers,
} from "./monaco/autoLanguage";

// CodeView usa el serializer/parser `.auto` completo (con control flow).
// Roundtrip estable serialize→parse→serialize (ver autoSerializer.test.ts).
//
// Monaco viene bundleado (setupMonaco) con lenguaje `.auto` (Monarch), tema
// "autopilot" (Tokyo Night), autocomplete del catálogo + labels del device,
// y markers de error del parser (#176/#181).

ensureMonacoSetup();

const MARKER_OWNER = "auto-parse";

export function CodeView() {
  const flow = useStore(selectCurrentFlow);
  const updateFlow = useStore((s) => s.updateFlow);
  const showToast = useStore((s) => s.showToast);

  const initial = useMemo(
    () => (flow ? serializeFlow(flow) : ""),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [flow?.id],
  );
  const [buffer, setBuffer] = useState(initial);
  const dirtyRef = useRef(false);
  const editorRef = useRef<Parameters<OnMount>[0] | null>(null);

  useEffect(() => {
    // Refresca el buffer solo si el usuario no está editando localmente —
    // evita borrar cambios no aplicados cuando se actualiza meta (status de
    // un bloque corriendo, por ejemplo).
    if (!dirtyRef.current && flow) setBuffer(serializeFlow(flow));
  }, [flow?.blocks, flow?.id]);

  // Parse live para contar líneas y detectar errores en tiempo real.
  const { blocks: parsedBlocks, errors: parseErrors } = useMemo(
    () => parseAuto(buffer),
    [buffer],
  );

  // #176: errores del parser → squiggles de Monaco con línea/columna.
  useEffect(() => {
    const model = editorRef.current?.getModel();
    if (!model) return;
    monaco.editor.setModelMarkers(
      model,
      MARKER_OWNER,
      parseErrorsToMarkers(parseErrors, buffer),
    );
  }, [parseErrors, buffer]);

  const onMount: OnMount = (editor) => {
    editorRef.current = editor;
    const model = editor.getModel();
    if (model) {
      monaco.editor.setModelMarkers(
        model,
        MARKER_OWNER,
        parseErrorsToMarkers(parseErrors, buffer),
      );
    }
  };

  function onApply() {
    if (!flow) return;
    if (parseErrors.length > 0) {
      // #176: feedback explícito — nada de silencio con errores.
      const first = parseErrors[0];
      showToast("err", `✗ línea ${first.line}: ${first.message}`);
      const ed = editorRef.current;
      if (ed) {
        ed.revealLineInCenterIfOutsideViewport(first.line);
        ed.setPosition({ lineNumber: first.line, column: 1 });
        ed.focus();
      }
      return;
    }
    // Regeneramos IDs al aplicar — se pierde meta.status/ms del run previo.
    // Mitigación futura: diff estructural para mantener IDs estables.
    updateFlow(flow.id, { blocks: parsedBlocks, updatedAt: Date.now() });
    dirtyRef.current = false;
    showToast("ok", `✓ ${parsedBlocks.length} bloque(s) aplicado(s)`);
  }

  function onRevert() {
    if (flow) setBuffer(serializeFlow(flow));
    dirtyRef.current = false;
  }

  if (!flow) {
    return (
      <div className="canvas">
        <div className="empty-state">
          <div>Sin flow seleccionado</div>
        </div>
      </div>
    );
  }

  return (
    <div className="canvas code-view" data-testid="code-view">
      <div className="code-view-toolbar">
        <span className="section-title">
          {flow.name} · <span className="mono">{parsedBlocks.length} bloque(s)</span>
          {parseErrors.length > 0 && (
            <span className="code-errors" style={{ color: "var(--coral)", marginLeft: 8 }}>
              ⚠ {parseErrors.length} error(es) · línea {parseErrors[0].line}
            </span>
          )}
        </span>
        <div style={{ flex: 1 }} />
        <button className="btn" onClick={onRevert} disabled={!dirtyRef.current} data-testid="code-revert">
          Revertir
        </button>
        <button
          className="btn btn-primary"
          onClick={onApply}
          title={
            parseErrors.length > 0
              ? `Corrige ${parseErrors.length} error(es) antes de aplicar`
              : "Aplicar cambios al flow"
          }
          data-testid="code-apply"
        >
          Aplicar
        </button>
      </div>
      <div className="code-view-editor">
        <Editor
          height="100%"
          language={AUTO_LANGUAGE_ID}
          theme={AUTO_THEME_ID}
          value={buffer}
          onMount={onMount}
          onChange={(v) => {
            setBuffer(v ?? "");
            dirtyRef.current = true;
          }}
          options={{
            fontSize: 13,
            fontFamily: "JetBrains Mono, ui-monospace, Menlo, monospace",
            minimap: { enabled: false },
            scrollBeyondLastLine: false,
            wordWrap: "on",
            lineNumbers: "on",
            renderLineHighlight: "all",
            padding: { top: 12 },
            quickSuggestions: { other: true, comments: false, strings: true },
            suggestOnTriggerCharacters: true,
            fixedOverflowWidgets: true,
          }}
        />
      </div>
    </div>
  );
}

export default CodeView;
