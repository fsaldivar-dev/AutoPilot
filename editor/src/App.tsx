import { useState, useRef, useCallback } from "react";
import Editor, { OnMount } from "@monaco-editor/react";
import { invoke } from "@tauri-apps/api/core";
import "./App.css";

const DEFAULT_SCRIPT = `# Mi script de automatizacion
# Escribe comandos y presiona Play

ping
tree -s "Login"
`;

const AUTO_COMMANDS = [
  // Conexion
  { label: "ping", detail: "Verificar conexion con Simulador" },

  // Inspeccion UI
  { label: "tree", detail: "Arbol de accesibilidad completo" },
  { label: "tree -s", detail: "Buscar elementos por texto", insertText: 'tree -s "${1:query}"' },
  { label: "exists", detail: "Verificar si elemento existe", insertText: 'exists "${1:element}"' },
  { label: "elementAt", detail: "Elemento en coordenada", insertText: "elementAt ${1:x} ${2:y}" },
  { label: "waitFor", detail: "Esperar a que aparezca", insertText: 'waitFor "${1:element}" ${2:10}' },

  // Interaccion
  { label: "tap", detail: "Tap en elemento", insertText: 'tap "${1:element}"' },
  { label: "doubleTap", detail: "Doble tap", insertText: 'doubleTap "${1:element}"' },
  { label: "longPress", detail: "Presion larga (segundos)", insertText: 'longPress "${1:element}" ${2:1}' },
  { label: "tapAt", detail: "Tap en coordenadas x y", insertText: "tapAt ${1:x} ${2:y}" },
  { label: "type", detail: "Escribir texto", insertText: 'type "${1:text}"' },
  { label: "clear", detail: "Limpiar campo de texto", insertText: 'clear "${1:field}"' },
  { label: "swipe", detail: "Deslizar pantalla", insertText: "swipe ${1|up,down,left,right|}" },
  { label: "scroll", detail: "Scroll dentro de elemento", insertText: 'scroll "${1:element}" ${2|down,up|}' },

  // Apps
  { label: "launch", detail: "Abrir app por bundle ID", insertText: "launch ${1:com.example.app}" },
  { label: "terminate", detail: "Cerrar app", insertText: "terminate ${1:com.example.app}" },
  { label: "install", detail: "Instalar .app en simulador", insertText: "install ${1:/path/to/app.app}" },

  // Simulador
  { label: "boot", detail: "Encender simulador", insertText: 'boot "${1:iPhone 17 Pro}"' },
  { label: "shutdown", detail: "Apagar simulador", insertText: 'shutdown "${1:iPhone 17 Pro}"' },
  { label: "list", detail: "Listar simuladores disponibles" },

  // Face ID
  { label: "faceid enroll", detail: "Activar Face ID en simulador" },
  { label: "faceid match", detail: "Simular escaneo exitoso" },
  { label: "faceid fail", detail: "Simular escaneo fallido" },
  { label: "faceid status", detail: "Verificar si Face ID esta activo" },

  // Camara
  { label: "camera start", detail: "Iniciar feed de camara virtual", insertText: "camera start ${1:image.jpg}" },
  { label: "camera feed", detail: "Actualizar imagen de camara", insertText: "camera feed ${1:image.jpg}" },
  { label: "camera stop", detail: "Detener camara virtual" },
  { label: "camera status", detail: "Estado de camara virtual" },
  { label: "build", detail: "Compilar app con mock de camara", insertText: "build -project ${1:App.xcodeproj} -scheme ${2:App} -sdk iphonesimulator -destination ${3:'id=XXXX'}" },

  // Datos
  { label: "screenshot", detail: "Captura de pantalla", insertText: "screenshot ${1:file.png}" },
  { label: "media", detail: "Inyectar foto a galeria", insertText: "media ${1:photo.jpg}" },
  { label: "paste", detail: "Escribir en portapapeles", insertText: 'paste "${1:text}"' },
  { label: "openurl", detail: "Abrir URL o deep link", insertText: 'openurl "${1:miapp://ruta}"' },

  // Scripting
  { label: "run", detail: "Ejecutar otro script .auto", insertText: "run ${1:script.auto}" },
];

function App() {
  const [script, setScript] = useState(DEFAULT_SCRIPT);
  const [output, setOutput] = useState("");
  const [running, setRunning] = useState(false);
  const [currentStep, setCurrentStep] = useState(-1);
  const [elements, setElements] = useState<string[]>([]);
  const editorRef = useRef<any>(null);
  const abortRef = useRef(false);

  const appendOutput = useCallback((text: string) => {
    setOutput((prev) => prev + text + "\n");
  }, []);

  const runScript = useCallback(async () => {
    setRunning(true);
    abortRef.current = false;
    setOutput("");

    const lines = script.split("\n");
    let stepNum = 0;

    for (let i = 0; i < lines.length; i++) {
      if (abortRef.current) {
        appendOutput("\n--- STOPPED ---");
        break;
      }

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

  const stopScript = useCallback(() => {
    abortRef.current = true;
  }, []);

  const refreshTree = useCallback(async () => {
    try {
      const result = await invoke<{ raw: string; elements: string[] }>("get_ax_tree");
      setElements(result.elements);
      appendOutput("--- AX Tree: " + result.elements.length + " elements ---");
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

        for (const el of elements) {
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
        ) : elements.length > 0 ? (
          <span>{elements.length} UI elements loaded</span>
        ) : (
          <span>Click Tree to load UI elements for autocomplete</span>
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
      if (c === quoteChar) {
        inQuote = false;
        args.push(current);
        current = "";
      } else {
        current += c;
      }
    } else if (c === '"' || c === "'") {
      inQuote = true;
      quoteChar = c;
    } else if (c === " ") {
      if (current) { args.push(current); current = ""; }
    } else {
      current += c;
    }
  }
  if (current) args.push(current);
  return args;
}

export default App;
