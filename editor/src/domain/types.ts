// AutoPilot Composer — core domain types.
// Mirrors the Rust db.rs rows for round-trip serialization.

export type Platform = "ios" | "android" | "both";

export type BlockStatus = "idle" | "running" | "ok" | "err";

export type BlockKind = "command" | "component" | "logic" | "comment";

// "else", "catch", "foreach" quedan como valores legacy reconocidos por migrate.ts;
// el editor no crea nuevos bloques con esos kinds. "assert" es nuevo.
export type LogicKind =
  | "if" | "else" | "repeat" | "try" | "catch" | "foreach" | "assert";

// AST de predicados — espejo de Predicate en cli/Sources/AutoCore/ScriptAST.swift.
// Se usa en if, repeat (while/until) y assert.
export type Predicate =
  | { kind: "call"; name: string; args: string[] }
  | { kind: "and"; left: Predicate; right: Predicate }
  | { kind: "or"; left: Predicate; right: Predicate }
  | { kind: "not"; inner: Predicate };

export type RepeatMode =
  | { mode: "times"; n: number }
  | { mode: "while"; pred: Predicate }
  | { mode: "until"; pred: Predicate }
  | { mode: "foreach"; variable: string; list: string };

export interface BlockMeta {
  status: BlockStatus;
  ms?: number;
  error?: string;
  ranAt?: number;
  screenshotId?: string;
}

export interface Block {
  id: string;
  kind: BlockKind;
  command?: string;
  args?: Record<string, string | number | boolean>;
  // For logic blocks: slots hold nested blocks
  //   if:     [then, else]
  //   repeat: [body]
  //   try:    [body, catch]
  //   assert: []
  slots?: Block[][];
  logicKind?: LogicKind;
  // Nuevo (solo logic):
  predicate?: Predicate;   // if / assert / repeat (while|until)
  repeat?: RepeatMode;     // repeat
  meta: BlockMeta;
}

export interface Param {
  name: string;
  type: "string" | "number" | "element" | "boolean" | "enum";
  secure?: boolean;
  default?: string;
  enumValues?: string[];
}

export interface Component {
  id: string;
  projectId: string;
  name: string;
  signature: Param[];
  returnType?: string;
  body: Block[];
  usageCount: number;
  createdFromFlowId?: string;
}

export interface EnvVar {
  projectId: string;
  scope: string; // "dev" | "staging" | "prod" | custom
  key: string;
  value: string;
  secret: boolean;
}

export interface Flow {
  id: string;
  projectId: string;
  name: string;
  blocks: Block[];
  entryBlockId?: string;
  updatedAt: number;
}

export interface DeviceRef {
  id: string;
  platform: Platform;
  name: string;
  udid?: string;
}

export interface Project {
  id: string;
  name: string;
  platform: Platform;
  flows: Flow[];
  components: Component[];
  env: EnvVar[];
  devices: DeviceRef[];
  createdAt: number;
  updatedAt: number;
}

// Run records — the execution history of a flow.

export type RunStatus = "running" | "passed" | "failed" | "cancelled";

export interface RunEvent {
  blockId: string;
  phase: "start" | "end";
  ok: boolean;
  ms?: number;
  out?: string;
  err?: string;
  screenshotId?: string;
  timestamp: number;
}

export interface RunRecord {
  id: string;
  flowId: string;
  startedAt: number;
  endedAt?: number;
  status: RunStatus;
  events: RunEvent[];
}

// Executor frames — mirror of Rust executor::Frame.

export interface Frame {
  ok: boolean;
  ms?: number;
  out?: string;
  err?: string;
  ready?: boolean;
  bye?: boolean;
  skip?: boolean;
  platform?: string;
}

// DB row shapes — the Tauri commands use these exact shapes.

export interface ProjectRow {
  id: string;
  name: string;
  platform: string;
  data: Record<string, unknown>;
  created_at: number;
  updated_at: number;
}

export interface FlowRow {
  id: string;
  project_id: string;
  name: string;
  data: { blocks: Block[]; entryBlockId?: string };
  updated_at: number;
}

export interface ComponentRow {
  id: string;
  project_id: string;
  name: string;
  signature: Param[];
  body: Block[];
  usage_count: number;
}

export interface EnvVarRow {
  project_id: string;
  scope: string;
  key: string;
  value: string;
  secret: boolean;
}

export interface RunRecordRow {
  id: string;
  flow_id: string;
  started_at: number;
  ended_at: number | null;
  status: string;
  events: RunEvent[];
}

// Autocomplete context & suggestions.

export type SuggestionKind =
  | "command"
  | "element"
  | "component"
  | "variable"
  | "recent"
  | "role"
  | "container"
  | "value";

export interface Suggestion {
  id: string;
  kind: SuggestionKind;
  label: string;
  detail?: string;
  signature?: string;
  insertText: string;
  score: number;
  icon?: string;
}

export interface CursorContext {
  input: string;
  cursor: number;
  token: string;
  insideBrackets: boolean;
  afterWithin: boolean;
  afterDollar: boolean;
  commandWord?: string;
  paramIndex?: number;
  // Cuando el popover está sobre un PredicateEditor, el provider de predicados
  // muestra `exists`, `visible`, `and/or/not`, etc. en el CommandBar normal es
  // undefined/false.
  predicateMode?: boolean;
}

// Live element index (from device).

export interface IndexedElement {
  index: number;
  role: string;
  label: string;
  frame: string;
}
