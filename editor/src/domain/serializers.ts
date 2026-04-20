// Converts between frontend (camelCase) types and DB rows (snake_case).

import type {
  Component,
  ComponentRow,
  EnvVar,
  EnvVarRow,
  Flow,
  FlowRow,
  Project,
  ProjectRow,
  RunRecord,
  RunRecordRow,
} from "./types";

export function projectToRow(p: Project): ProjectRow {
  return {
    id: p.id,
    name: p.name,
    platform: p.platform,
    data: {
      devices: p.devices,
    },
    created_at: p.createdAt,
    updated_at: p.updatedAt,
  };
}

export function rowToProject(
  r: ProjectRow,
  flows: Flow[] = [],
  components: Component[] = [],
  env: EnvVar[] = []
): Project {
  const data = (r.data ?? {}) as { devices?: Project["devices"] };
  return {
    id: r.id,
    name: r.name,
    platform: (r.platform as Project["platform"]) ?? "ios",
    flows,
    components,
    env,
    devices: data.devices ?? [],
    createdAt: r.created_at,
    updatedAt: r.updated_at,
  };
}

export function flowToRow(f: Flow): FlowRow {
  return {
    id: f.id,
    project_id: f.projectId,
    name: f.name,
    data: { blocks: f.blocks, entryBlockId: f.entryBlockId },
    updated_at: f.updatedAt,
  };
}

export function rowToFlow(r: FlowRow): Flow {
  return {
    id: r.id,
    projectId: r.project_id,
    name: r.name,
    blocks: r.data.blocks ?? [],
    entryBlockId: r.data.entryBlockId,
    updatedAt: r.updated_at,
  };
}

export function componentToRow(c: Component): ComponentRow {
  return {
    id: c.id,
    project_id: c.projectId,
    name: c.name,
    signature: c.signature,
    body: c.body,
    usage_count: c.usageCount,
  };
}

export function rowToComponent(r: ComponentRow): Component {
  return {
    id: r.id,
    projectId: r.project_id,
    name: r.name,
    signature: r.signature,
    body: r.body,
    usageCount: r.usage_count,
  };
}

export function envVarToRow(e: EnvVar): EnvVarRow {
  return {
    project_id: e.projectId,
    scope: e.scope,
    key: e.key,
    value: e.value,
    secret: e.secret,
  };
}

export function rowToEnvVar(r: EnvVarRow): EnvVar {
  return {
    projectId: r.project_id,
    scope: r.scope,
    key: r.key,
    value: r.value,
    secret: r.secret,
  };
}

export function runToRow(r: RunRecord): RunRecordRow {
  return {
    id: r.id,
    flow_id: r.flowId,
    started_at: r.startedAt,
    ended_at: r.endedAt ?? null,
    status: r.status,
    events: r.events,
  };
}

export function rowToRun(r: RunRecordRow): RunRecord {
  return {
    id: r.id,
    flowId: r.flow_id,
    startedAt: r.started_at,
    endedAt: r.ended_at ?? undefined,
    status: r.status as RunRecord["status"],
    events: r.events ?? [],
  };
}
