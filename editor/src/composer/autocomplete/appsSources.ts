import type { InstalledApp, Project } from "../../domain/types";

// Fuentes de bundleId para el predictivo (#187), en orden de prioridad:
// proyecto (wizard) → en pantalla (root del tree) → instaladas (`auto apps`).
// Compartido por CommandBar, InlineCommandEditor y Monaco.

export interface AppSource {
  bundle: string;
  name: string;
  source: "proyecto" | "en pantalla" | "instalada";
}

export function appSuggestionSources(
  project: Pick<Project, "name" | "bundleId"> | undefined | null,
  detectedApp: { name: string; bundle: string } | null,
  installedApps: InstalledApp[]
): AppSource[] {
  const out: AppSource[] = [];
  const seen = new Set<string>();
  const push = (a: AppSource) => {
    if (!a.bundle || seen.has(a.bundle)) return;
    seen.add(a.bundle);
    out.push(a);
  };
  if (project?.bundleId) {
    push({ bundle: project.bundleId, name: project.name, source: "proyecto" });
  }
  if (detectedApp) {
    push({ bundle: detectedApp.bundle, name: detectedApp.name, source: "en pantalla" });
  }
  for (const a of installedApps) {
    push({ bundle: a.bundle, name: a.name, source: "instalada" });
  }
  return out;
}

// Parsea el output de `auto apps` / `auto-android apps`: una línea por app
// `bundleId<TAB>nombre`. Líneas sin tab (mensajes, vacías) se ignoran.
export function parseAppsOutput(out: string): InstalledApp[] {
  const apps: InstalledApp[] = [];
  for (const line of out.split("\n")) {
    const tab = line.indexOf("\t");
    if (tab <= 0) continue;
    const bundle = line.slice(0, tab).trim();
    const name = line.slice(tab + 1).trim() || bundle;
    if (bundle) apps.push({ bundle, name });
  }
  return apps;
}
