import { useStore } from "../state/store";
import * as executor from "./executor";
import type { IndexedElement } from "../domain/types";

// Refresh compartido del tree/index del device (#189). Lo usan:
// - CommandBar / InlineCommandEditor / Monaco: auto-fetch cuando el cursor
//   está en un param `element` y el store no tiene elementos (antes solo
//   mostraban el hint pasivo «corre tree»)
// - DevicePreview: refresh post-acción con debounce (el screenshot rápido
//   mantiene el mirror fluido; esto mantiene el predictivo fresco)
//
// CRÍTICO: con sesión viva, el `index` corre DENTRO de la sesión interactiva
// (observer → sin robo de foco y sin el chrome del Simulator). El camino
// frío `invoke("inspect")` spawnea un `auto` fresco que cae al tree AX de
// macOS: devuelve «Volume Up/Down/Action» (botones del Simulator, no de la
// app) y le roba el foco al usuario — solo se usa sin sesión.

// Roles interactivos o etiquetables que valen como target de tap/type —
// mismo criterio que ElementIndex del CLI.
const INTERACTIVE = /Button|TextField|TextArea|SecureTextField|CheckBox|Slider|Tab|Cell|Switch|Link/;
const LABELED_OK = /StaticText|Heading|Image/;

// Parsea el output de `tree` (printElement del CLI, iOS y Android):
//   `  AXButton  "Titulo"  label="Label"  id=ident  [x,y wxh]`
// Cada campo es opcional salvo role. El predictivo inserta `"label"` (nunca
// $N), así que los índices son solo presentación — no hay riesgo de desfase
// con el ElementIndex del CLI (#190).
export function parseTreeOutput(out: string): IndexedElement[] {
  const elements: IndexedElement[] = [];
  const re =
    /^\s*(AX\w+|\w+)(?:\s+"(.*?)")?(?:\s+label="(.*?)")?(?:\s+id=(\S+))?\s+\[(-?\d+),(-?\d+)\s+(\d+)x(\d+)\]\s*$/;
  for (const line of out.split("\n")) {
    const m = re.exec(line);
    if (!m) continue;
    const role = m[1].replace(/^AX/, "");
    const label = m[3] ?? m[2] ?? "";
    if (!INTERACTIVE.test(role) && !(label && LABELED_OK.test(role))) continue;
    if (!label && !m[4]) continue;
    elements.push({
      index: elements.length,
      role,
      label: label || (m[4] ?? ""),
      frame: `[${m[5]},${m[6]} ${m[7]}x${m[8]}]`,
    });
  }
  return elements;
}

let inFlight = false;
let lastFetch = 0;

export function resetElementsThrottleForTests(): void {
  inFlight = false;
  lastFetch = 0;
}

// Evita tormentas de fetch: un solo vuelo a la vez y mínimo `minIntervalMs`
// entre fetches.
export async function ensureFreshElements(
  platform: "ios" | "android",
  minIntervalMs = 1500
): Promise<void> {
  const now = Date.now();
  if (inFlight || now - lastFetch < minIntervalMs) return;
  inFlight = true;
  try {
    const st = useStore.getState();

    if (st.sessionId) {
      // `tree` (no `index`): con observer vivo el tree es in-app — sin el
      // chrome del Simulator y sin foco. `index` sigue colgado del AX de
      // macOS (#190) y devuelve Volume Up/Action como $0-$3.
      // sendWithRecover: si la sesión murió (app reiniciada, CLI caído),
      // respawnea y reintenta — el predictivo no se queda ciego (#188).
      const { frame, sessionId } = await executor.sendWithRecover(
        platform,
        st.sessionId,
        "tree",
        15_000
      );
      lastFetch = Date.now();
      if (sessionId !== st.sessionId) {
        useStore.getState().setSession(sessionId, platform);
      }
      if (frame.ok) {
        const parsed = parseTreeOutput(frame.out ?? "");
        if (parsed.length > 0) useStore.getState().setElements(parsed);
      }
      return;
    }

    // Sin sesión NO hay fetch: el inspect frío usa el path AX (roba foco y
    // devuelve el chrome del Simulator). El hint del input ya dice «corre
    // launch para ver los elementos». El inspect frío queda solo para el
    // botón ↻ manual de DevicePreview (acción explícita del usuario).
  } catch {
    // Best-effort: sin device/sesión el predictivo se queda con lo que hay.
  } finally {
    inFlight = false;
  }
}
