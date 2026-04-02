import { useState, useRef, useCallback } from "react";
import Editor, { OnMount } from "@monaco-editor/react";
import { invoke } from "@tauri-apps/api/core";
import Inspector from "./Inspector";
import "./App.css";

const DEFAULT_SCRIPT = `# Mi script de automatizacion
# Escribe comandos y presiona Play
# Click Tree para ver elementos del Simulator

ping
`;

const AUTO_COMMANDS = [
  { label: "ping", detail: "Verificar conexion" },
  { label: "tree", detail: "Arbol de accesibilidad" },
  { label: "tree -s", detail: "Buscar elementos", insertText: 'tree -s "${1:query}"' },
  { label: "tap", detail: "Tap en elemento", insertText: 'tap "${1:element}"' },
  { label: "tap (multi)", detail: "Tap varios elementos", insertText: "tap ${1:1,2,3,4,Confirmar}" },
  { label: "doubleTap", detail: "Doble tap", insertText: 'doubleTap "${1:element}"' },
  { label: "longPress", detail: "Presion larga", insertText: 'longPress "${1:element}" ${2:1}' },
  { label: "tapAt", detail: "Tap coordenadas", insertText: "tapAt ${1:x} ${2:y}" },
  { label: "type", detail: "Escribir texto", insertText: 'type "${1:text}"' },
  { label: "clear", detail: "Limpiar campo", insertText: 'clear "${1:field}"' },
  { label: "swipe", detail: "Deslizar", insertText: "swipe ${1|up,down,left,right|}" },
  { label: "scroll", detail: "Scroll elemento", insertText: 'scroll "${1:element}" ${2|down,up|}' },
  { label: "exists", detail: "Verificar existencia", insertText: 'exists "${1:element}"' },
  { label: "waitFor", detail: "Esperar elemento", insertText: 'waitFor "${1:element}" ${2:10}' },
  { label: "elementAt", detail: "Elemento en coordenada", insertText: "elementAt ${1:x} ${2:y}" },
  { label: "screenshot", detail: "Captura de pantalla", insertText: "screenshot ${1:file.png}" },
  { label: "launch", detail: "Abrir app", insertText: "launch ${1:com.example.app}" },
  { label: "terminate", detail: "Cerrar app", insertText: "terminate ${1:com.example.app}" },
  { label: "install", detail: "Instalar app", insertText: "install ${1:/path/to/app.app}" },
  { label: "boot", detail: "Encender simulador", insertText: 'boot "${1:iPhone 17 Pro}"' },
  { label: "shutdown", detail: "Apagar simulador", insertText: 'shutdown "${1:iPhone 17 Pro}"' },
  { label: "list", detail: "Listar simuladores" },
  { label: "faceid enroll", detail: "Activar Face ID" },
  { label: "faceid match", detail: "Face ID exitoso" },
  { label: "faceid fail", detail: "Face ID fallido" },
  { label: "faceid status", detail: "Estado Face ID" },
  { label: "camera start", detail: "Iniciar camara virtual", insertText: "camera start ${1:image.jpg}" },
  { label: "camera feed", detail: "Actualizar imagen", insertText: "camera feed ${1:image.jpg}" },
  { label: "camera stop", detail: "Detener camara" },
  { label: "camera status", detail: "Estado camara" },
  { label: "build", detail: "Compilar con mock", insertText: "build -project ${1:App.xcodeproj} -scheme ${2:App} -sdk iphonesimulator -destination ${3:'id=XXXX'}" },
  { label: "media", detail: "Inyectar foto a galeria", insertText: "media ${1:photo.jpg}" },
  { label: "paste", detail: "Portapapeles", insertText: 'paste "${1:text}"' },
  { label: "openurl", detail: "Abrir URL", insertText: 'openurl "${1:miapp://ruta}"' },
  { label: "run", detail: "Ejecutar script", insertText: "run ${1:script.auto}" },
];

interface AXElement {
  role: string;
  label: string;
  id: string;
  value: string;
  frame: string;
  depth: number;
  display: string;
}

function App() {
  const [script, setScript] = useState(DEFAULT_SCRIPT);
  const [output, setOutput] = useState("");
  const [running, setRunning] = useState(false);
  const [currentStep, setCurrentStep] = useState(-1);
  const [treeElements, setTreeElements] = useState<AXElement[]>([]);
  const [labels, setLabels] = useState<string[]>([]);
  const [indexed, setIndexed] = useState<any[]>([]);
  const [screenshot, setScreenshot] = useState("");
  const [showTree, setShowTree] = useState(false);
  const editorRef = useRef<any>(null);
  const abortRef = useRef(false);
  const indexedRef = useRef<any[]>([]);
  const labelsRef = useRef<string[]>([]);

  const appendOutput = useCallback((text: string) => {
    setOutput((prev) => prev + text + "\n");
  }, []);

  const insertToEditor = useCallback((text: string) => {
    setScript((prev) => prev.trimEnd() + "\n" + text + "\n");
    setSelectedElement(null);
  }, []);

  const runScript = useCallback(async () => {
    setRunning(true);
    abortRef.current = false;
    setOutput("");
    const lines = script.split("\n");
    let stepNum = 0;
    for (let i = 0; i < lines.length; i++) {
      if (abortRef.current) { appendOutput("\n--- STOPPED ---"); break; }
      const trimmed = lines[i].trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      stepNum++;
      setCurrentStep(i);
      appendOutput(`[${stepNum}] ${trimmed}`);
      try {
        const args = parseCommand(trimmed);
        const result = await invoke<string>("run_auto", { args });
        if (result.trim()) appendOutput(result.trim());
      } catch (err: any) {
        appendOutput(`ERROR: ${err}`);
        break;
      }
    }
    appendOutput(`\n${stepNum} step(s) completed`);
    setCurrentStep(-1);
    setRunning(false);
  }, [script, appendOutput]);

  const stopScript = useCallback(() => { abortRef.current = true; }, []);

  const refreshTree = useCallback(async () => {
    try {
      appendOutput("--- Capturing screenshot + tree + index... ---");
      const result = await invoke<{ screenshot: string; elements: AXElement[]; labels: string[]; indexed: any[] }>("inspect");
      setTreeElements(result.elements);
      setLabels(result.labels);
      setIndexed(result.indexed || []);
      indexedRef.current = result.indexed || [];
      labelsRef.current = result.labels;
      setScreenshot(result.screenshot);
      setShowTree(true);
      appendOutput("--- Inspector: " + result.elements.length + " elements, " + (result.indexed?.length || 0) + " indexed ---");
    } catch (err: any) {
      appendOutput(`Inspect error: ${err}`);
    }
  }, [appendOutput]);

  const handleEditorMount: OnMount = (editor, monaco) => {
    editorRef.current = editor;

    monaco.languages.register({ id: "auto" });
    monaco.languages.setMonarchTokensProvider("auto", {
      tokenizer: {
        root: [
          [/#.*$/, "comment"],
          [/"[^"]*"/, "string"],
          [/'[^']*'/, "string"],
          [/\b(ping|tree|tap|doubleTap|longPress|type|clear|swipe|scroll|tapAt|elementAt|exists|waitFor|screenshot|launch|terminate|install|faceid|paste|openurl|media|build|camera|run|boot|shutdown|list)\b/, "keyword"],
          [/\b(enroll|match|fail|status|start|feed|stop|up|down|left|right)\b/, "type"],
          [/--env\b/, "annotation"],
          [/\b\d+\b/, "number"],
        ],
      },
    });

    monaco.languages.registerCompletionItemProvider("auto", {
      triggerCharacters: ["$"],
      provideCompletionItems: (model, position) => {
        const line = model.getLineContent(position.lineNumber);
        const beforeCursor = line.substring(0, position.column - 1);

        // If typing $... show indexed elements
        const dollarMatch = beforeCursor.match(/\$(\w*)$/);
        if (dollarMatch) {
          const currentIndexed = indexedRef.current;
          // Group indexed by label to show [N] for duplicates
          const byLabel: Record<string, typeof currentIndexed[number][]> = {};
          for (const el of currentIndexed) {
            const key = el.label || el.role;
            if (!byLabel[key]) byLabel[key] = [];
            byLabel[key].push(el);
          }

          const suggestions = currentIndexed.map((el) => {
            const group = byLabel[el.label || el.role] || [];
            const hasMultiple = group.length > 1;
            const occurrence = hasMultiple ? group.indexOf(el) + 1 : 0;
            const suffix = hasMultiple ? `[${occurrence}]` : "";
            const displayLabel = el.label || el.role;

            return {
              label: `$${displayLabel}${suffix}`,
              kind: monaco.languages.CompletionItemKind.Variable,
              detail: `${el.role} ${el.frame}`,
              insertText: hasMultiple ? `${displayLabel}${suffix}` : displayLabel,
              sortText: `0_${displayLabel}_${String(occurrence).padStart(2, "0")}`,
              filterText: `$${displayLabel}`,
            };
          });

          return { suggestions } as any;
        }

        // Default: command suggestions + labels
        const suggestions = AUTO_COMMANDS.map((cmd) => ({
          label: cmd.label,
          kind: monaco.languages.CompletionItemKind.Function,
          detail: cmd.detail,
          insertText: cmd.insertText || cmd.label,
          insertTextRules: cmd.insertText
            ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet
            : undefined,
        }));
        for (const el of labelsRef.current) {
          suggestions.push({
            label: `"${el}"`,
            kind: monaco.languages.CompletionItemKind.Value,
            detail: "UI Element",
            insertText: `"${el}"`,
            insertTextRules: undefined,
          });
        }
        return { suggestions } as any;
      },
    });

    monaco.editor.defineTheme("autopilot", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "keyword", foreground: "FF6B6B", fontStyle: "bold" },
        { token: "string", foreground: "98C379" },
        { token: "comment", foreground: "5C6370", fontStyle: "italic" },
        { token: "type", foreground: "61AFEF" },
        { token: "annotation", foreground: "E5C07B" },
        { token: "number", foreground: "D19A66" },
      ],
      colors: {
        "editor.background": "#1A1B26",
        "editor.foreground": "#C0CAF5",
        "editorCursor.foreground": "#FF6B6B",
        "editor.lineHighlightBackground": "#24283B",
        "editor.selectionBackground": "#33467C",
      },
    });
    monaco.editor.setTheme("autopilot");
  };

  return (
    <div className="app">
      <header className="toolbar">
        <div className="toolbar-left">
          <span className="logo">AutoPilot</span>
          <span className="separator" />
          <span className="filename">script.auto</span>
        </div>
        <div className="toolbar-right">
          <button className="btn btn-tree" onClick={refreshTree} disabled={running}>
            <span className="btn-icon">🌳</span> Inspect
          </button>
          {!running ? (
            <button className="btn btn-play" onClick={runScript}>
              <span className="btn-icon">▶</span> Play
            </button>
          ) : (
            <button className="btn btn-stop" onClick={stopScript}>
              <span className="btn-icon">■</span> Stop
            </button>
          )}
        </div>
      </header>

      <div className="main-area">
        {/* Left: Inspector (Preview / Tree tabs) */}
        {showTree && (
          <Inspector
            elements={treeElements}
            indexed={indexed}
            screenshot={screenshot}
            onInsert={insertToEditor}
            onClose={() => setShowTree(false)}
          />
        )}

        {/* Center + Bottom */}
        <div className="editor-area">
          {/* Editor */}
          <section className="editor-panel">
            <Editor
              defaultLanguage="auto"
              value={script}
              onChange={(v) => setScript(v || "")}
              onMount={handleEditorMount}
              options={{
                fontSize: 14,
                fontFamily: "'SF Mono', 'Fira Code', 'Menlo', monospace",
                minimap: { enabled: false },
                lineNumbers: "on",
                scrollBeyondLastLine: false,
                wordWrap: "off",
                padding: { top: 12 },
                suggestOnTriggerCharacters: true,
                quickSuggestions: true,
                tabSize: 2,
                renderLineHighlight: "all",
                cursorBlinking: "smooth",
              }}
            />
          </section>

          {/* Bottom: Terminal-style output */}
          <section className="terminal-panel">
            <div className="terminal-header">
              <span>Terminal</span>
              {running && <span className="running-indicator" />}
              <button className="btn-clear" onClick={() => setOutput("")}>Clear</button>
            </div>
            <pre className="terminal-content">
              {output || "$ auto run script.auto\nReady..."}
            </pre>
          </section>
        </div>
      </div>

      <footer className="statusbar">
        {running ? (
          <span>Running step {currentStep + 1}...</span>
        ) : labels.length > 0 ? (
          <span>{labels.length} UI elements | {treeElements.length} nodes</span>
        ) : (
          <span>Click Inspect to capture Simulator UI</span>
        )}
      </footer>
    </div>
  );
}

function parseCommand(line: string): string[] {
  const args: string[] = [];
  let current = "";
  let inQuote = false;
  let quoteChar = "";
  for (const c of line) {
    if (inQuote) {
      if (c === quoteChar) { inQuote = false; args.push(current); current = ""; }
      else { current += c; }
    } else if (c === '"' || c === "'") { inQuote = true; quoteChar = c; }
    else if (c === " ") { if (current) { args.push(current); current = ""; } }
    else { current += c; }
  }
  if (current) args.push(current);
  return args;
}

export default App;
