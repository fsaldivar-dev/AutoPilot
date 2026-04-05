import { useState, useRef, useCallback, useEffect } from "react";
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
  // Conexión
  { label: "ping", detail: "Verificar conexion" },
  { label: "list", detail: "Listar dispositivos" },
  { label: "boot", detail: "Encender dispositivo", insertText: 'boot "${1:iPhone 17 Pro}"' },
  { label: "shutdown", detail: "Apagar dispositivo", insertText: 'shutdown "${1:device}"' },

  // Inspección
  { label: "tree", detail: "Arbol de accesibilidad" },
  { label: "tree -s", detail: "Buscar elementos", insertText: 'tree -s "${1:query}"' },
  { label: "exists", detail: "Verificar existencia", insertText: 'exists "${1:element}"' },
  { label: "waitFor", detail: "Esperar elemento", insertText: 'waitFor "${1:element}" ${2:10}' },
  { label: "elementAt", detail: "Elemento en coordenada", insertText: "elementAt ${1:x} ${2:y}" },
  { label: "index", detail: "Listar elementos con $N" },
  { label: "inspect", detail: "Inspeccionar elemento", insertText: 'inspect "${1:query}"' },
  { label: "inspect --context", detail: "Parent chain + within suggestions", insertText: 'inspect "${1:query}" --context' },

  // Interacción
  { label: "tap", detail: "Tap en elemento", insertText: 'tap "${1:element}"' },
  { label: "tap[role]", detail: "Tap con role verification", insertText: 'tap[${1|button,textField,textArea,checkBox,slider,tab|}] "${2:element}"' },
  { label: "tap within", detail: "Tap con scope", insertText: 'tap "${1:element}" within "${2:scope}"' },
  { label: "tap[role] within", detail: "Tap con role + scope", insertText: 'tap[${1|button,textField,textArea|}] "${2:element}" within "${3:scope}"' },
  { label: "tap (multi)", detail: "Tap varios elementos", insertText: "tap ${1:a,b,c}" },
  { label: "doubleTap", detail: "Doble tap", insertText: 'doubleTap "${1:element}"' },
  { label: "longPress", detail: "Presion larga", insertText: 'longPress "${1:element}" ${2:1}' },
  { label: "tapAt", detail: "Tap coordenadas", insertText: "tapAt ${1:x} ${2:y}" },
  { label: "type", detail: "Escribir texto", insertText: 'type "${1:text}"' },
  { label: "type (en campo)", detail: "Tap campo + escribir", insertText: 'type "${1:campo}" "${2:texto}"' },
  { label: "clear", detail: "Limpiar campo", insertText: 'clear "${1:field}"' },
  { label: "swipe", detail: "Deslizar", insertText: "swipe ${1|up,down,left,right|}" },
  { label: "scroll", detail: "Scroll elemento", insertText: 'scroll "${1:element}" ${2|down,up|}' },

  // App
  { label: "launch", detail: "Abrir app", insertText: "launch ${1:dev.autopilot.test.Explorea}" },
  { label: "terminate", detail: "Cerrar app", insertText: "terminate ${1:dev.autopilot.test.Explorea}" },
  { label: "install", detail: "Instalar app", insertText: "install ${1:/path/to/app}" },

  // Timing
  { label: "wait", detail: "Pausar N segundos", insertText: "wait ${1:2}" },
  { label: "sleep", detail: "Alias de wait", insertText: "sleep ${1:1}" },

  // Captura
  { label: "screenshot", detail: "Captura de pantalla", insertText: "screenshot ${1:file.png}" },

  // Biometría
  { label: "biometric enroll", detail: "Enrollar biometría (idempotente)" },
  { label: "biometric unenroll", detail: "Des-enrollar biometría" },
  { label: "biometric match", detail: "Biometría exitosa" },
  { label: "biometric fail", detail: "Biometría fallida" },
  { label: "biometric status", detail: "Estado biometría" },

  // Cámara
  { label: "camera start", detail: "Iniciar camara virtual", insertText: "camera start ${1:image.jpg}" },
  { label: "camera feed", detail: "Actualizar imagen", insertText: "camera feed ${1:image.jpg}" },
  { label: "camera stop", detail: "Detener camara" },
  { label: "camera status", detail: "Estado camara" },
  { label: "inject", detail: "Cambiar imagen mock (iOS)", insertText: "inject ${1:image.jpg}" },

  // Build (iOS)
  { label: "build", detail: "Compilar con mock", insertText: "build -project ${1:App.xcodeproj} -scheme ${2:App}", platform: "ios" as const },

  // Drag
  { label: "drag", detail: "Arrastrar entre elementos", insertText: 'drag "${1:from}" "${2:to}"' },
  { label: "drag (coords)", detail: "Arrastrar entre coordenadas", insertText: "drag ${1:x1},${2:y1} ${3:x2},${4:y2}" },

  // Rotacion
  { label: "rotate", detail: "Rotar dispositivo", insertText: "rotate ${1|left,right,portrait,landscape|}" },

  // Teclado
  { label: "pressKey", detail: "Presionar tecla", insertText: 'pressKey "${1|home,back,enter,delete,volumeUp,volumeDown,power,tab,escape|}"' },
  { label: "hideKeyboard", detail: "Ocultar teclado" },
  { label: "eraseText", detail: "Borrar N caracteres", insertText: "eraseText ${1:10}" },

  // Texto
  { label: "copyTextFrom", detail: "Leer texto de elemento", insertText: 'copyTextFrom "${1:elemento}"' },

  // App Data
  { label: "clearState", detail: "Borrar datos de app", insertText: 'clearState "${1:com.example.app}"' },
  { label: "uninstall", detail: "Desinstalar app", insertText: 'uninstall "${1:com.example.app}"' },

  // Scroll
  { label: "scrollTo", detail: "Scroll hasta encontrar elemento", insertText: 'scrollTo "${1:elemento}"' },

  // Grabacion
  { label: "startRecording", detail: "Iniciar grabacion de pantalla" },
  { label: "stopRecording", detail: "Detener grabacion", insertText: 'stopRecording "${1:video.mp4}"' },

  // Entorno
  { label: "setLocation", detail: "GPS simulado", insertText: "setLocation ${1:19.4326} ${2:-99.1332}" },
  { label: "setAppearance", detail: "Modo oscuro/claro", insertText: 'setAppearance "${1|dark,light|}"' },
  { label: "lockDevice", detail: "Bloquear pantalla" },
  { label: "unlockDevice", detail: "Desbloquear pantalla" },

  // Archivos
  { label: "pushFile", detail: "Enviar archivo al dispositivo", insertText: 'pushFile "${1:local/path}" "${2:/remote/path}"' },
  { label: "pullFile", detail: "Traer archivo del dispositivo", insertText: 'pullFile "${1:/remote/path}" "${2:local/path}"' },

  // Permisos
  { label: "permission", detail: "Permisos de app", insertText: 'permission ${1|grant,revoke,reset|} ${2|camera,photos,location,all|} ${3:com.example.app}' },

  // Logs
  { label: "logs", detail: "Ver logs de app", insertText: 'logs "${1:com.example.app}"' },
  { label: "logs (system)", detail: "Logs del sistema", insertText: "logs --system" },

  // Media y datos
  { label: "media", detail: "Inyectar foto a galeria", insertText: "media ${1:photo.jpg}" },
  { label: "paste", detail: "Portapapeles", insertText: 'paste "${1:text}"' },
  { label: "openurl", detail: "Abrir URL", insertText: 'openurl "${1:miapp://ruta}"' },

  // Config
  { label: "config", detail: "Ver configuracion" },
  { label: "config (set)", detail: "Configurar valor", insertText: "config ${1:bundle} ${2:dev.autopilot.test.Explorea}" },

  // Script
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
  const [platform, setPlatform] = useState<"ios" | "android">("ios");
  const editorRef = useRef<any>(null);
  const abortRef = useRef(false);
  const indexedRef = useRef<any[]>([]);
  const labelsRef = useRef<string[]>([]);
  const platformRef = useRef<"ios" | "android">(platform);

  useEffect(() => { platformRef.current = platform; }, [platform]);

  const appendOutput = useCallback((text: string) => {
    setOutput((prev) => prev + text + "\n");
  }, []);

  const insertToEditor = useCallback((text: string) => {
    setScript((prev) => prev.trimEnd() + "\n" + text + "\n");
  }, []);

  const runScript = useCallback(async () => {
    setRunning(true);
    abortRef.current = false;
    setOutput("");
    const editor = editorRef.current;
    let decorations: string[] = [];
    const lines = script.split("\n");
    let stepNum = 0;
    for (let i = 0; i < lines.length; i++) {
      if (abortRef.current) { appendOutput("\n--- STOPPED ---"); break; }
      const trimmed = lines[i].trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      stepNum++;
      setCurrentStep(i);
      // Highlight active line in editor
      if (editor) {
        const lineNum = i + 1;
        decorations = editor.deltaDecorations(decorations, [{
          range: { startLineNumber: lineNum, startColumn: 1, endLineNumber: lineNum, endColumn: 1 },
          options: { isWholeLine: true, className: "active-step-line" },
        }]);
        editor.revealLineInCenter(lineNum);
      }
      appendOutput(`[${stepNum}] ${trimmed}`);
      try {
        const args = parseCommand(trimmed);
        const result = await invoke<string>("run_auto", { args, platform });
        if (result.trim()) appendOutput(result.trim());
      } catch (err: any) {
        appendOutput(`ERROR: ${err}`);
        break;
      }
    }
    // Clear highlight
    if (editor) editor.deltaDecorations(decorations, []);
    appendOutput(`\n${stepNum} step(s) completed`);
    setCurrentStep(-1);
    setRunning(false);
  }, [script, appendOutput, platform]);

  const stopScript = useCallback(() => { abortRef.current = true; }, []);

  const refreshTree = useCallback(async () => {
    try {
      appendOutput("--- Capturing screenshot + tree + index... ---");
      const result = await invoke<{ screenshot: string; elements: AXElement[]; labels: string[]; indexed: any[] }>("inspect", { platform });
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
  }, [appendOutput, platform]);

  const handleEditorMount: OnMount = (editor, monaco) => {
    editorRef.current = editor;

    monaco.languages.register({ id: "auto" });
    monaco.languages.setMonarchTokensProvider("auto", {
      keywords: [
        "ping", "tree", "tap", "doubleTap", "longPress", "type", "clear",
        "swipe", "scroll", "tapAt", "elementAt", "exists", "waitFor", "wait",
        "sleep", "screenshot", "launch", "terminate", "install", "biometric",
        "faceid", "paste", "openurl", "media", "build", "camera", "inject",
        "index", "inspect", "config", "run", "boot", "shutdown", "list",
        "drag", "rotate", "permission", "logs",
        "pressKey", "hideKeyboard", "eraseText", "copyTextFrom",
        "clearState", "uninstall", "scrollTo",
        "startRecording", "stopRecording",
        "setLocation", "setAppearance", "lockDevice", "unlockDevice",
        "pushFile", "pullFile",
      ],
      subcommands: [
        "enroll", "match", "fail", "status", "start", "feed", "stop",
        "up", "down", "left", "right", "dark", "light",
        "home", "back", "enter", "delete", "volumeUp", "volumeDown",
        "power", "tab", "escape", "grant", "revoke", "reset",
        "portrait", "landscape",
      ],
      contextKeywords: ["within"],
      roles: ["button", "textField", "textArea", "checkBox", "slider", "tab", "image", "switch"],
      tokenizer: {
        root: [
          [/#.*$/, "comment"],
          [/"[^"]*"/, "string"],
          [/'[^']*'/, "string"],
          [/\[/, { token: "delimiter.bracket", next: "@role" }],
          [/--\w+/, "annotation"],
          [/\d+(\.\d+)?/, "number"],
          [/[a-zA-Z]\w*/, {
            cases: {
              "@keywords": "keyword",
              "@contextKeywords": "keyword.context",
              "@subcommands": "type",
              "@default": "identifier",
            },
          }],
        ],
        role: [
          [/[a-zA-Z]\w*/, {
            cases: {
              "@roles": "type.role",
              "@default": "identifier",
            },
          }],
          [/\]/, { token: "delimiter.bracket", next: "@pop" }],
        ],
      },
    });

    monaco.languages.registerCompletionItemProvider("auto", {
      triggerCharacters: [" ", "["],
      provideCompletionItems: (model: any, position: any) => {
        const line = model.getLineContent(position.lineNumber);
        const textBefore = line.substring(0, position.column - 1);

        // Context: inside [...] → suggest roles
        if (/\w+\[[^\]]*$/.test(textBefore)) {
          const roles = ["button", "textField", "textArea", "checkBox", "slider", "tab", "image", "switch"];
          return {
            suggestions: roles.map(r => ({
              label: r,
              kind: monaco.languages.CompletionItemKind.TypeParameter,
              detail: `Role: AX${r.charAt(0).toUpperCase() + r.slice(1)}`,
              insertText: r,
              sortText: `0_${r}`,
            })),
          };
        }

        // Context: after "within" → suggest parent elements from tree
        if (/\bwithin\s+$/.test(textBefore)) {
          const currentIndexed = indexedRef.current;
          const containers = currentIndexed.filter((el: any) => {
            const r = (el.role || "").toLowerCase();
            return r.includes("group") || r.includes("toolbar") || r.includes("list") ||
                   r.includes("scrollarea") || r.includes("table") || r.includes("navigationbar") ||
                   r.includes("tabbar");
          });
          return {
            suggestions: containers.map((el: any) => ({
              label: el.label || el.role,
              kind: monaco.languages.CompletionItemKind.Module,
              detail: `${el.role} ${el.frame}`,
              insertText: `"${el.label || el.role}"`,
              sortText: `0_${el.label}`,
            })),
          };
        }

        const currentIndexed = indexedRef.current;
        const suggestions: any[] = [];

        // 1. Commands (filtered by platform)
        const currentPlatform = platformRef.current;
        for (const cmd of AUTO_COMMANDS) {
          if ((cmd as any).platform && (cmd as any).platform !== currentPlatform) continue;
          suggestions.push({
            label: cmd.label,
            kind: monaco.languages.CompletionItemKind.Function,
            detail: cmd.detail,
            insertText: cmd.insertText || cmd.label,
            insertTextRules: cmd.insertText
              ? monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet
              : undefined,
            sortText: `1_${cmd.label}`,
          });
        }

        // 2. Indexed UI elements (with [N] for duplicates + role tag)
        const roleTagMap: Record<string, string> = {
          Button: "button", TextField: "textField", TextArea: "textArea",
          CheckBox: "checkBox", Slider: "slider", Tab: "tab",
          Image: "image", Switch: "switch",
        };
        const getRoleTag = (role: string): string | null => {
          for (const [key, tag] of Object.entries(roleTagMap)) {
            if (role.includes(key)) return tag;
          }
          return null;
        };

        const byLabel: Record<string, any[]> = {};
        for (const el of currentIndexed) {
          const key = el.label || el.role;
          if (!byLabel[key]) byLabel[key] = [];
          byLabel[key].push(el);
        }

        // Detect if we're after a command keyword (e.g. "tap ")
        const afterCommand = /^\s*(tap|doubleTap|longPress|clear|scroll|type|waitFor|exists|copyTextFrom|scrollTo)\s+$/i.test(textBefore);
        // Detect if we're after a command with role (e.g. "tap[button] ")
        const afterCommandWithRole = /^\s*\w+\[\w+\]\s+$/.test(textBefore);

        for (const el of currentIndexed) {
          const displayLabel = el.label || el.role;
          if (!displayLabel) continue;
          const group = byLabel[displayLabel] || [];
          const hasMultiple = group.length > 1;
          const occurrence = hasMultiple ? group.indexOf(el) + 1 : 0;
          const suffix = hasMultiple ? `[${occurrence}]` : "";
          const ref = `${displayLabel}${suffix}`;
          const tag = getRoleTag(el.role || "");

          // Build insertText based on context
          let insert: string;
          if (afterCommand && tag) {
            // After "tap " → replace command and insert with role: backspace + tap[button] "Camera"
            // Can't backspace, so just insert quoted ref — the role tag comes from command suggestions
            insert = `"${ref}"`;
          } else if (afterCommand || afterCommandWithRole) {
            insert = `"${ref}"`;
          } else {
            insert = ref;
          }

          suggestions.push({
            label: `${ref} ${el.role?.replace("AX", "") || ""}`,
            kind: monaco.languages.CompletionItemKind.Variable,
            detail: `${el.role}  ${el.frame}`,
            insertText: insert,
            sortText: `0_${displayLabel}_${String(occurrence).padStart(2, "0")}`,
          });
        }

        return { suggestions };
      },
    });

    monaco.editor.defineTheme("autopilot", {
      base: "vs-dark",
      inherit: true,
      rules: [
        { token: "keyword", foreground: "FF6B6B", fontStyle: "bold" },
        { token: "keyword.context", foreground: "C678DD", fontStyle: "bold" },
        { token: "string", foreground: "98C379" },
        { token: "comment", foreground: "5C6370", fontStyle: "italic" },
        { token: "type", foreground: "61AFEF" },
        { token: "type.role", foreground: "E5C07B", fontStyle: "italic" },
        { token: "delimiter.bracket", foreground: "ABB2BF" },
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

    // Cmd+Enter to run script
    editor.addAction({
      id: "run-script",
      label: "Run Script",
      keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.Enter],
      run: () => {
        const runBtn = document.querySelector(".btn-play") as HTMLButtonElement;
        if (runBtn && !runBtn.disabled) runBtn.click();
      },
    });

    // Cmd+I to inspect
    editor.addAction({
      id: "inspect-ui",
      label: "Inspect UI",
      keybindings: [monaco.KeyMod.CtrlCmd | monaco.KeyCode.KeyI],
      run: () => {
        const inspectBtn = document.querySelector(".btn-tree") as HTMLButtonElement;
        if (inspectBtn && !inspectBtn.disabled) inspectBtn.click();
      },
    });
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
          <div className="platform-toggle">
            <button
              className={`platform-btn ${platform === "ios" ? "active" : ""}`}
              onClick={() => setPlatform("ios")}
              disabled={running}
            >iOS</button>
            <button
              className={`platform-btn ${platform === "android" ? "active" : ""}`}
              onClick={() => setPlatform("android")}
              disabled={running}
            >Android</button>
          </div>
          <button className="btn btn-tree" onClick={refreshTree} disabled={running} title="Inspect Simulator UI (⌘I)">
            <span className="btn-icon">🌳</span> Inspect
          </button>
          {!running ? (
            <button className="btn btn-play" onClick={runScript} title="Run script (⌘↵)">
              <span className="btn-icon">▶</span> Play
            </button>
          ) : (
            <button className="btn btn-stop" onClick={stopScript} title="Stop execution">
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
              <button className="btn-clear" onClick={async () => {
                try { await invoke("open_screenshots"); } catch {}
              }}>📂 Screenshots</button>
              <button className="btn-clear" onClick={() => setOutput("")}>Clear</button>
            </div>
            <pre className="terminal-content" ref={(el) => { if (el) el.scrollTop = el.scrollHeight; }}>
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
          <span>{platform === "ios" ? "Click Inspect to capture Simulator UI" : "Click Inspect to capture Android UI"}</span>
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
