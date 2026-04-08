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
  // Conexion
  { label: "ping", detail: "Verificar conexion" },
  { label: "list", detail: "Listar dispositivos" },
  { label: "boot", detail: "Encender dispositivo", insertText: 'boot "${1:iPhone 17 Pro}"' },
  { label: "shutdown", detail: "Apagar dispositivo", insertText: 'shutdown "${1:device}"' },

  // Inspeccion
  { label: "tree", detail: "Arbol de accesibilidad (opcional: -s 'query' para buscar)", insertText: 'tree${1| ,-s "query"|}' },
  { label: "exists", detail: "Verificar si un elemento esta en el tree", insertText: 'exists "${1:element}"' },
  { label: "waitFor", detail: "Esperar a que un elemento aparezca (timeout en segundos, default 10)", insertText: 'waitFor "${1:element}" ${2:10}' },
  { label: "waitUntilGone", detail: "Esperar a que un elemento desaparezca (inverso de waitFor)", insertText: 'waitUntilGone "${1:element}" ${2:10}' },
  { label: "elementAt", detail: "Elemento en coordenada (x,y)", insertText: "elementAt ${1:x} ${2:y}" },
  { label: "index", detail: "Listar elementos con $N (despues podes usar 'tap $N')" },
  { label: "inspect", detail: "Inspeccionar elemento (--context muestra parent chain)", insertText: 'inspect "${1:query}"${2| ,--context|}' },

  // Interaccion
  { label: "tap", detail: "Tap en elemento (por label o id)", insertText: 'tap "${1:element}"' },
  { label: "tap[role]", detail: "Tap con role verification (preferible cuando hay siblings ambiguos)", insertText: 'tap[${1|button,textfield,checkbox,radiobutton,popupbutton,slider,link,menuitem,tab,cell,switch,toggle,segmentedcontrol,picker,stepper|}] "${2:element}"' },
  { label: "tap within", detail: "Tap con scope: search restringido a un container", insertText: 'tap "${1:element}" within "${2:scope}"' },
  { label: 'tap "label[N]"', detail: "Tap N-esima ocurrencia del mismo label (1-indexed)", insertText: 'tap "${1:label}[${2:2}]"' },
  { label: "tap $N", detail: "Tap por element index (requiere 'index' previo)", insertText: "tap \\$${1:0}" },
  { label: "doubleTap", detail: "Doble tap", insertText: 'doubleTap "${1:element}"' },
  { label: "longPress", detail: "Presion larga (segundos)", insertText: 'longPress "${1:element}" ${2:1}' },
  { label: "tapAt", detail: "Tap por coordenadas absolutas", insertText: "tapAt ${1:x} ${2:y}" },
  { label: "type", detail: "Escribir texto en el field actualmente focused", insertText: 'type "${1:text}"' },
  { label: 'type "campo" "texto"', detail: "Tap field por label + escribir (smart: prefiere text inputs sobre StaticText sibling)", insertText: 'type "${1:campo}" "${2:texto}"' },
  { label: "type[N]", detail: "Tap el N-esimo text input del tree + escribir (filtra por rol)", insertText: 'type[${1|1,2,3|}] "${2:text}"' },
  { label: "clear", detail: "Limpiar text field", insertText: 'clear "${1:field}"' },
  { label: "swipe", detail: "Deslizar (gesture global)", insertText: "swipe ${1|up,down,left,right|}" },
  { label: "scroll", detail: "Scroll dentro de un elemento", insertText: 'scroll "${1:element}" ${2|down,up,left,right|}' },

  // App lifecycle
  { label: "launch", detail: "Abrir app", insertText: "launch ${1:com.example.app}" },
  { label: "terminate", detail: "Cerrar app", insertText: "terminate ${1:com.example.app}" },
  { label: "install", detail: "Instalar app (.app iOS / .apk Android)", insertText: "install ${1:/path/to/app}" },
  { label: "uninstall", detail: "Desinstalar app", insertText: 'uninstall "${1:com.example.app}"' },
  { label: "clearState", detail: "Borrar datos de app (no borra keychain compartido en iOS)", insertText: 'clearState "${1:com.example.app}"' },

  // Timing
  { label: "wait", detail: "Pausar N segundos", insertText: "wait ${1:2}" },

  // Captura
  { label: "screenshot", detail: "Captura de pantalla (PNG)", insertText: "screenshot ${1:file.png}" },

  // Biometria
  { label: "biometric enroll", detail: "Enrollar biometria (idempotente)" },
  { label: "biometric unenroll", detail: "Des-enrollar biometria" },
  { label: "biometric match", detail: "Biometria exitosa (Face ID / fingerprint OK)" },
  { label: "biometric fail", detail: "Biometria fallida" },
  { label: "biometric status", detail: "Estado biometria" },

  // Camara (iOS only)
  { label: "camera start", detail: "Iniciar camara virtual con imagen", insertText: "camera start ${1:image.jpg}", platform: "ios" as const },
  { label: "camera feed", detail: "Actualizar imagen del feed (hot swap)", insertText: "camera feed ${1:image.jpg}", platform: "ios" as const },
  { label: "camera stop", detail: "Detener camara virtual", platform: "ios" as const },
  { label: "camera status", detail: "Estado camara", platform: "ios" as const },
  { label: "inject", detail: "Hot-swap imagen mock sin relaunch", insertText: "inject ${1:image.jpg}", platform: "ios" as const },

  // Build (iOS only)
  { label: "build", detail: "Compilar con mock", insertText: "build -project ${1:App.xcodeproj} -scheme ${2:App}", platform: "ios" as const },

  // Drag
  { label: "drag", detail: "Arrastrar entre elementos", insertText: 'drag "${1:from}" "${2:to}"' },
  { label: "drag (coords)", detail: "Arrastrar entre coordenadas", insertText: "drag ${1:x1},${2:y1} ${3:x2},${4:y2}" },

  // Orientacion
  { label: "rotate", detail: "Rotar dispositivo", insertText: "rotate ${1|left,right,portrait,landscape|}" },

  // Teclado
  { label: "pressKey", detail: "Presionar tecla (iOS: home/enter/delete/tab/escape/volumeUp/down — Android: home/back/enter/delete/volumeUp/down/power)", insertText: 'pressKey "${1|home,back,enter,delete,tab,escape,volumeUp,volumeDown,power|}"' },
  { label: "hideKeyboard", detail: "Ocultar teclado virtual" },
  { label: "eraseText", detail: "Borrar N caracteres del field actual", insertText: "eraseText ${1:10}" },

  // Lectura de texto
  { label: "copyTextFrom", detail: "Leer texto de un elemento", insertText: 'copyTextFrom "${1:elemento}"' },

  // Scroll busqueda
  { label: "scrollTo", detail: "Scroll hasta hacer visible un elemento", insertText: 'scrollTo "${1:elemento}"' },

  // Grabacion de pantalla
  { label: "startRecording", detail: "Iniciar grabacion de pantalla (video)" },
  { label: "stopRecording", detail: "Detener grabacion y guardar a archivo", insertText: 'stopRecording "${1:video.mp4}"' },

  // Entorno del dispositivo
  { label: "setLocation", detail: "GPS simulado (lat lon)", insertText: "setLocation ${1:lat} ${2:lon}" },
  { label: "setAppearance", detail: "Modo oscuro/claro", insertText: 'setAppearance "${1|dark,light|}"' },
  { label: "lockDevice", detail: "Bloquear pantalla" },
  { label: "unlockDevice", detail: "Desbloquear pantalla" },

  // Archivos
  { label: "pushFile", detail: "Enviar archivo al dispositivo", insertText: 'pushFile "${1:local/path}" "${2:/remote/path}"' },
  { label: "pullFile", detail: "Traer archivo del dispositivo", insertText: 'pullFile "${1:/remote/path}" "${2:local/path}"' },

  // Permisos
  { label: "permission", detail: "Permisos de app (grant/revoke/reset)", insertText: 'permission ${1|grant,revoke,reset|} ${2|camera,microphone,photos,contacts,calendars,reminders,location,bluetooth,health,homekit,notifications,all|} ${3:com.example.app}' },

  // Logs
  { label: "logs", detail: "Logs de app o del sistema", insertText: 'logs ${1|"com.example.app",--system|}' },

  // Media y clipboard
  { label: "media", detail: "Inyectar foto a la galeria", insertText: "media ${1:photo.jpg}" },
  { label: "paste", detail: "Portapapeles (sin args = leer; con texto = escribir)", insertText: 'paste "${1:text}"' },
  { label: "openurl", detail: "Abrir URL via deeplink", insertText: 'openurl "${1:miapp://ruta}"' },

  // Diagnostico y setup
  { label: "doctor", detail: "Diagnosticar el bridge (Simulator AX, agente Android, DNS, etc.)" },
  { label: "setup", detail: "Re-armar adb forward + relanzar agente nativo", platform: "android" as const },
  { label: "--legacy", detail: "Usar AdbLegacyBridge en lugar del AgentBridge default", insertText: "--legacy ${1:command}", platform: "android" as const },

  // Config (.autopilot)
  { label: "config", detail: "Ver configuracion .autopilot" },
  { label: "config (set)", detail: "Setear valor del .autopilot", insertText: "config ${1:bundle} ${2:com.example.app}" },

  // Scripts
  { label: "run", detail: "Ejecutar script .auto", insertText: "run ${1:script.auto}" },
  { label: "record", detail: "Grabar acciones del usuario a un .auto (Ctrl+C para detener)", insertText: "record ${1:script.auto}" },
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

  const refreshTree = useCallback(async (opts?: { silent?: boolean }) => {
    const silent = opts?.silent === true;
    try {
      if (!silent) appendOutput("--- Capturing screenshot + tree + index... ---");
      const result = await invoke<{ screenshot: string; elements: AXElement[]; labels: string[]; indexed: any[] }>("inspect", { platform });
      setTreeElements(result.elements);
      setLabels(result.labels);
      setIndexed(result.indexed || []);
      indexedRef.current = result.indexed || [];
      labelsRef.current = result.labels;
      if (!silent) {
        setScreenshot(result.screenshot);
        setShowTree(true);
        appendOutput("--- Inspector: " + result.elements.length + " elements, " + (result.indexed?.length || 0) + " indexed ---");
      }
    } catch (err: any) {
      if (!silent) appendOutput(`Inspect error: ${err}`);
    }
  }, [appendOutput, platform]);

  const runScript = useCallback(async () => {
    setRunning(true);
    abortRef.current = false;
    setOutput("");

    // Start (or re-start) the interactive sidecar. The CLI's REPL keeps a
    // warm bridge + UIStabilizer alive across commands, so we no longer need
    // a client-side quiet period between steps — the stabilizer does it
    // right before each mutator, based on real AX events rather than a
    // fixed sleep.
    try {
      const banner = await invoke<string>("interactive_start", { platform });
      // Banner is a JSON line like {"ready":true,"platform":"ios"}. Surface
      // a friendlier message; fall back to the raw banner if parsing fails.
      let bannerText = banner;
      try {
        const parsed = JSON.parse(banner);
        if (parsed.ready) bannerText = `ready (${parsed.platform ?? platform})`;
      } catch {}
      appendOutput(`--- sidecar ${bannerText} ---`);
    } catch (err: any) {
      appendOutput(`ERROR starting interactive sidecar: ${err}`);
      setRunning(false);
      return;
    }

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
        const responseStr = await invoke<string>("interactive_send", { line: trimmed });
        // Protocol: one NDJSON envelope per line. Fields: ok, ms, out?, err?.
        let response: any;
        try {
          response = JSON.parse(responseStr);
        } catch {
          appendOutput(`ERROR: malformed sidecar response: ${responseStr}`);
          break;
        }
        if (response.out) appendOutput(response.out);
        if (!response.ok) {
          appendOutput(`ERROR: ${response.err ?? "command failed"}`);
          break;
        }
      } catch (err: any) {
        // If the user hit Stop mid-run, interactive_stop() closes the
        // sidecar's stdin/stdout underneath us and the current
        // interactive_send() call rejects. Treat that as a clean abort
        // rather than an error.
        if (abortRef.current) {
          appendOutput("\n--- STOPPED ---");
        } else {
          appendOutput(`ERROR: ${err}`);
        }
        break;
      }
    }
    // Clear highlight
    if (editor) editor.deltaDecorations(decorations, []);
    appendOutput(`\n${stepNum} step(s) completed`);
    setCurrentStep(-1);
    // Auto-refresh tree silenciosamente para que el autocomplete prediga
    // los elementos del estado final estable de la app (post observation
    // protocol). No contamina el panel de output ni abre el inspector visual.
    try { await refreshTree({ silent: true }); } catch {}
    setRunning(false);
  }, [script, appendOutput, platform, refreshTree]);

  const stopScript = useCallback(async () => {
    abortRef.current = true;
    try { await invoke("interactive_stop"); } catch {}
  }, []);

  // Switching platforms tears down the sidecar so the next run starts fresh
  // on the new platform's bridge. We also tear it down on unmount to avoid
  // orphaned subprocesses if the window closes mid-run.
  useEffect(() => {
    return () => { invoke("interactive_stop").catch(() => {}); };
  }, [platform]);
  useEffect(() => {
    return () => { invoke("interactive_stop").catch(() => {}); };
  }, []);

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
          <button className="btn btn-tree" onClick={() => refreshTree()} disabled={running} title="Inspect Simulator UI (⌘I)">
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

export default App;
