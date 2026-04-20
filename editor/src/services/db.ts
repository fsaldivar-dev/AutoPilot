// Frontend wrapper around DB Tauri commands.

import { invoke } from "@tauri-apps/api/core";
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
} from "../domain/types";
import {
  componentToRow,
  envVarToRow,
  flowToRow,
  projectToRow,
  rowToComponent,
  rowToEnvVar,
  rowToFlow,
  rowToProject,
  rowToRun,
  runToRow,
} from "../domain/serializers";

export async function listProjects(): Promise<Project[]> {
  const rows = await invoke<ProjectRow[]>("db_list_projects");
  return rows.map((r) => rowToProject(r));
}

export async function upsertProject(p: Project): Promise<void> {
  await invoke("db_upsert_project", { row: projectToRow(p) });
}

export async function deleteProject(id: string): Promise<void> {
  await invoke("db_delete_project", { id });
}

export async function listFlows(projectId: string): Promise<Flow[]> {
  const rows = await invoke<FlowRow[]>("db_list_flows", { projectId });
  return rows.map((r) => rowToFlow(r));
}

export async function upsertFlow(f: Flow): Promise<void> {
  await invoke("db_upsert_flow", { row: flowToRow(f) });
}

export async function deleteFlow(id: string): Promise<void> {
  await invoke("db_delete_flow", { id });
}

export async function listComponents(projectId: string): Promise<Component[]> {
  const rows = await invoke<ComponentRow[]>("db_list_components", { projectId });
  return rows.map((r) => rowToComponent(r));
}

export async function upsertComponent(c: Component): Promise<void> {
  await invoke("db_upsert_component", { row: componentToRow(c) });
}

export async function deleteComponent(id: string): Promise<void> {
  await invoke("db_delete_component", { id });
}

export async function listEnvVars(projectId: string): Promise<EnvVar[]> {
  const rows = await invoke<EnvVarRow[]>("db_list_env_vars", { projectId });
  return rows.map((r) => rowToEnvVar(r));
}

export async function upsertEnvVar(ev: EnvVar): Promise<void> {
  await invoke("db_upsert_env_var", { row: envVarToRow(ev) });
}

export async function deleteEnvVar(
  projectId: string,
  scope: string,
  key: string
): Promise<void> {
  await invoke("db_delete_env_var", { projectId, scope, key });
}

export async function saveRun(r: RunRecord): Promise<void> {
  await invoke("db_save_run", { row: runToRow(r) });
}

export async function listRuns(
  flowId: string,
  limit?: number
): Promise<RunRecord[]> {
  const rows = await invoke<RunRecordRow[]>("db_list_runs", { flowId, limit });
  return rows.map((r) => rowToRun(r));
}
