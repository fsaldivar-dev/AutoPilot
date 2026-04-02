import { useState, useRef, useCallback } from "react";
import Editor, { OnMount } from "@monaco-editor/react";
import { invoke } from "@tauri-apps/api/core";
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

const ELEMENT_ACTIONS = [
  { label: "tap", icon: "👆", cmd: (el: string) => `tap "${el}"` },
  { label: "doubleTap", icon: "👆👆", cmd: (el: string) => `doubleTap "${el}"` },
  { label: "longPress", icon: "✊", cmd: (el: string) => `longPress "${el}" 1` },
  { label: "type", icon: "⌨️", cmd: (el: string) => `type "${el}" "text"` },
  { label: "clear", icon: "🗑", cmd: (el: string) => `clear "${el}"` },
  { label: "exists", icon: "❓", cmd: (el: string) => `exists "${el}"` },
  { label: "waitFor", icon: "⏳", cmd: (el: string) => `waitFor "${el}" 10` },
  { label: "scroll", icon: "📜", cmd: (el: string) => `scroll "${el}" down` },
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
  const [showTree, setShowTree] = useState(false);
  const [selectedElement, setSelectedElement] = useState<AXElement | null>(null);
  const editorRef = useRef<any>(null);
  const abortRef = useRef(false);

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
      const result = await invoke<{ raw: string; elements: AXElement[]; labels: string[] }>("get_ax_tree");
      setTreeElements(result.elements);
      setLabels(result.labels);
      setShowTree(true);
      appendOutput("--- Tree: " + result.elements.length + " elements ---");
    } catch (err: any) {
      appendOutput(`Tree error: ${err}`);
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
      provideCompletionItems: () => {
        const suggestions = AUTO_COMMANDS.map((cmd) => ({
          label: cmd.label,
          kind: monaco.languages.CompletionItemKind.Function,
          detail: cmd.detail,
          insertText: cmd.insertText || cmd.label,
          insertTextRules: cmd.insertText
            ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet
            : undefined,
        }));
        for (const el of labels) {
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

  const roleIcon = (role: string) => {
    if (role.includes("Button")) return "🔘";
    if (role.includes("TextField") || role.includes("TextArea")) return "📝";
    if (role.includes("StaticText")) return "📄";
    if (role.includes("Image")) return "🖼";
    if (role.includes("Group")) return "📦";
    if (role.includes("Heading")) return "🏷";
    if (role.includes("Tab")) return "📑";
    if (role.includes("Slider")) return "🎚";
    if (role.includes("CheckBox") || role.includes("Toggle")) return "☑️";
    if (role.includes("Toolbar")) return "🔧";
    return "◻️";
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
            <span className="btn-icon">🌳</span> Tree
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

      <main className="panels">
        {showTree && (
          <section className="tree-panel">
            <div className="tree-header">
              <span>Inspector ({treeElements.length})</span>
              <button className="btn-close" onClick={() => setShowTree(false)}>×</button>
            </div>
            <div className="tree-list">
              {treeElements.map((el, i) => (
                <div key={i} className={`tree-item ${selectedElement === el ? "selected" : ""}`}
                  style={{ paddingLeft: `${8 + el.depth * 12}px` }}
                  onClick={() => setSelectedElement(selectedElement === el ? null : el)}>
                  <span className="tree-icon">{roleIcon(el.role)}</span>
                  <span className="tree-role">{el.role.replace("AX", "")}</span>
                  {el.display && el.display !== el.role && (
                    <span className="tree-label">{el.display}</span>
                  )}
                  {el.frame && <span className="tree-frame">{el.frame}</span>}
                  {selectedElement === el && (
                    <div className="action-menu" onClick={(e) => e.stopPropagation()}>
                      {ELEMENT_ACTIONS.map((action) => (
                        <button key={action.label} className="action-btn"
                          onClick={() => insertToEditor(action.cmd(el.display || el.role))}>
                          <span>{action.icon}</span> {action.label}
                        </button>
                      ))}
                    </div>
                  )}
                </div>
              ))}
            </div>
          </section>
        )}

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
              wordWrap: "on",
              padding: { top: 12 },
              suggestOnTriggerCharacters: true,
              quickSuggestions: true,
              tabSize: 2,
              renderLineHighlight: "all",
              cursorBlinking: "smooth",
            }}
          />
        </section>

        <section className="output-panel">
          <div className="output-header">
            <span>Output</span>
            {running && <span className="running-indicator" />}
          </div>
          <pre className="output-content">
            {output || "Press Play to run script..."}
          </pre>
        </section>
      </main>

      <footer className="statusbar">
        {running ? (
          <span>Running step {currentStep + 1}...</span>
        ) : labels.length > 0 ? (
          <span>{labels.length} UI elements | {treeElements.length} nodes</span>
        ) : (
          <span>Click Tree to inspect Simulator UI</span>
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
