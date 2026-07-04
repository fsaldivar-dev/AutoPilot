// Wiring de Monaco para el lenguaje `.auto`.
//
// CRÍTICO offline: @monaco-editor/react por default baja Monaco de un CDN
// (jsdelivr) — en la app Tauri sin red eso deja la vista Código pelada
// (textarea de fallback sin ninguna feature). Aquí apuntamos el loader al
// monaco-editor BUNDLEADO por Vite y registramos el worker local.
//
// El autocomplete consume el MISMO motor que los Bloques (#185/#186):
// suggest() + expectationAt() — elementos del device, enums del catálogo,
// plataforma del toggle. Monaco solo agrega la capa estructural multilínea
// (snippets de control flow, end/else/catch conscientes del bloque abierto).
//
// Este módulo se importa solo desde CodeView (que AppShell carga lazy), así
// el chunk de Monaco no engorda el bundle inicial del composer.

import * as monaco from "monaco-editor";
import editorWorker from "monaco-editor/esm/vs/editor/editor.worker?worker";
import { loader } from "@monaco-editor/react";
import {
  AUTO_LANGUAGE_CONF,
  AUTO_LANGUAGE_ID,
  AUTO_THEME,
  AUTO_THEME_ID,
  buildMonarchLanguage,
  logicSnippets,
  openBlockStack,
} from "./autoLanguage";
import { expectationAt, suggest, tokenize } from "../autocomplete";
import { matchCommandLine, renderSignature } from "../catalog";
import type { SuggestionKind } from "../../domain/types";
import { useStore } from "../../state/store";

let installed = false;

const KIND_MAP: Record<SuggestionKind, monaco.languages.CompletionItemKind> = {
  command: monaco.languages.CompletionItemKind.Function,
  element: monaco.languages.CompletionItemKind.Value,
  component: monaco.languages.CompletionItemKind.Module,
  variable: monaco.languages.CompletionItemKind.Variable,
  recent: monaco.languages.CompletionItemKind.Reference,
  role: monaco.languages.CompletionItemKind.Class,
  container: monaco.languages.CompletionItemKind.Folder,
  value: monaco.languages.CompletionItemKind.EnumMember,
};

function currentPlatform(): "ios" | "android" {
  return useStore.getState().uiPlatform === "android" ? "android" : "ios";
}

export function ensureMonacoSetup(): void {
  if (installed) return;
  installed = true;

  // Workers locales — sin red. Solo usamos el lenguaje custom `.auto`, así
  // que el editor worker genérico cubre todo (tokens, diffs, word-based).
  self.MonacoEnvironment = {
    getWorker: () => new editorWorker(),
  };

  // Monaco bundleado, NO CDN.
  loader.config({ monaco });

  monaco.languages.register({ id: AUTO_LANGUAGE_ID, extensions: [".auto"] });
  monaco.languages.setMonarchTokensProvider(AUTO_LANGUAGE_ID, buildMonarchLanguage());
  monaco.languages.setLanguageConfiguration(AUTO_LANGUAGE_ID, AUTO_LANGUAGE_CONF);
  monaco.editor.defineTheme(AUTO_THEME_ID, AUTO_THEME);

  monaco.languages.registerCompletionItemProvider(AUTO_LANGUAGE_ID, {
    triggerCharacters: [" ", '"', "$"],
    provideCompletionItems(model, position) {
      const line = model.getLineContent(position.lineNumber);
      const cursor = position.column - 1;
      const platform = currentPlatform();
      const st = useStore.getState();
      const project = st.projects.find((p) => p.id === st.currentProjectId);

      // Rango a reemplazar: el token actual según el MISMO tokenizer que los
      // Bloques, extendido a la comilla/$ previa cuando el insertText la trae
      // (si no, `tap "Inic` + aceptar produciría comilla doble).
      const token = tokenize(line, cursor).token;
      const tokenStartColumn = position.column - token.length;
      const rangeFor = (insertText: string): monaco.Range => {
        let start = tokenStartColumn;
        const prev = line[start - 2];
        if (insertText.startsWith('"') && prev === '"') start -= 1;
        if (insertText.startsWith("$") && prev === "$") start -= 1;
        return new monaco.Range(
          position.lineNumber,
          start,
          position.lineNumber,
          position.column,
        );
      };

      const shared = suggest({
        input: line,
        cursor,
        platform,
        elements: st.elements,
        components: project?.components ?? [],
        envVars: project?.env ?? [],
        recents: st.recentBlocks,
      });

      const suggestions: monaco.languages.CompletionItem[] = shared.map((s, i) => ({
        label: s.label,
        kind: KIND_MAP[s.kind] ?? monaco.languages.CompletionItemKind.Text,
        detail: s.signature ?? s.detail,
        insertText: s.insertText,
        sortText: `1_${String(i).padStart(3, "0")}`,
        range: rangeFor(s.insertText),
      }));

      // Capa estructural (#186): snippets de control flow en región de
      // comando; end/else/catch solo con un bloque abierto arriba.
      const exp = expectationAt(line, cursor, platform);
      if (exp.kind === "command") {
        const linesAbove: string[] = [];
        for (let n = 1; n < position.lineNumber; n++) {
          linesAbove.push(model.getLineContent(n));
        }
        const stack = openBlockStack(linesAbove);
        logicSnippets(stack[stack.length - 1]).forEach((sn, i) => {
          suggestions.push({
            label: sn.label,
            kind: monaco.languages.CompletionItemKind.Snippet,
            detail: sn.detail,
            insertText: sn.insertText,
            insertTextRules:
              monaco.languages.CompletionItemInsertTextRule.InsertAsSnippet,
            // Cierres del bloque abierto arriba de todo; el resto de snippets
            // después de comandos/elementos.
            sortText: sn.closer
              ? `0_${String(i).padStart(3, "0")}`
              : `2_${String(i).padStart(3, "0")}`,
            range: rangeFor(sn.insertText),
          });
        });
      }

      return { suggestions };
    },
  });

  // Hover: doc del catálogo sobre la línea del comando.
  monaco.languages.registerHoverProvider(AUTO_LANGUAGE_ID, {
    provideHover(model, position) {
      const line = model.getLineContent(position.lineNumber).trim();
      const cmd = matchCommandLine(line, currentPlatform());
      if (!cmd) return null;
      return {
        contents: [
          { value: "```\n" + renderSignature(cmd) + "\n```" },
          {
            value: `${cmd.description}\n\nEjemplo: \`${cmd.example}\` · plataforma: ${cmd.platform}`,
          },
        ],
      };
    },
  });
}

export { monaco };
