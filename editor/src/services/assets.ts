import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { useStore } from "../state/store";
import type { Project } from "../domain/types";

// Assets del proyecto (#194): el proyecto es una carpeta real
// (~/AutoPilot Projects/<nombre>/) y las imágenes importadas se COPIAN a
// images/ (estilo «Copy items if needed» de Xcode). Cada asset vive como
// variable del proyecto (scope "asset"): la sustitución de $nombre en
// flowRunner y el predictivo tras $ funcionan sin código nuevo.

// Slug compatible con la regex de substituteVars: [A-Za-z_][A-Za-z0-9_.]*
export function assetKey(fileName: string): string {
  const stem = fileName.replace(/\.[^.]+$/, "");
  let key = stem.replace(/[^A-Za-z0-9_.]/g, "_");
  if (!/^[A-Za-z_]/.test(key)) key = `_${key}`;
  return key;
}

export async function ensureProjectDir(project: Project): Promise<string> {
  if (project.rootDir) return project.rootDir;
  const dir = await invoke<string>("project_ensure", { name: project.name });
  useStore.getState().setProjectRootDir(project.id, dir);
  return dir;
}

// Abre el diálogo nativo, copia la imagen a images/ y registra la variable
// $<slug> → images/<archivo>. Devuelve la key o null si se canceló.
export async function importAssetViaDialog(project: Project): Promise<string | null> {
  const src = await open({
    multiple: false,
    directory: false,
    filters: [{ name: "Imágenes", extensions: ["png", "jpg", "jpeg", "gif", "heic", "webp"] }],
  });
  if (!src || typeof src !== "string") return null;

  const dir = await ensureProjectDir(project);
  const rel = await invoke<string>("project_import_asset", {
    projectDir: dir,
    srcPath: src,
  });
  const key = assetKey(rel.replace(/^images\//, ""));
  useStore.getState().upsertEnvVar(project.id, {
    projectId: project.id,
    scope: "asset",
    key,
    value: rel,
    secret: false,
  });
  return key;
}
