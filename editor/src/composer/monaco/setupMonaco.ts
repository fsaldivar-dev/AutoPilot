// Wiring de Monaco para el lenguaje `.auto`.
//
// CRÍTICO offline: @monaco-editor/react por default baja Monaco de un CDN
// (jsdelivr) — en la app Tauri sin red eso deja la vista Código pelada
// (textarea de fallback sin ninguna feature). Aquí apuntamos el loader al
// monaco-editor BUNDLEADO por Vite y registramos el worker local.
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
  buildCommandCompletions,
  buildElementCompletions,
  buildMonarchLanguage,
  lineExpectsElement,
} from "./autoLanguage";
import { useStore } from "../../state/store";

let installed = false;

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
      const lineUntilCursor = model
        .getLineContent(position.lineNumber)
        .slice(0, position.column - 1);
      const word = model.getWordUntilPosition(position);
      const range = new monaco.Range(
        position.lineNumber,
        word.startColumn,
        position.lineNumber,
        word.endColumn,
      );

      // Tras un comando que espera target (tap, waitFor, …): labels reales
      // del device conectado — la misma data que usa el composer (store.elements).
      if (lineExpectsElement(lineUntilCursor)) {
        const elements = useStore.getState().elements;
        const suggestions = buildElementCompletions(elements).map((s) => ({
          label: s.label,
          kind: monaco.languages.CompletionItemKind.Value,
          detail: s.detail,
          documentation: s.documentation,
          insertText: s.insertText,
          sortText: s.sortText,
          range,
        }));
        return { suggestions };
      }

      // Primer token de la línea: los 69 comandos del catálogo con firma.
      const suggestions = buildCommandCompletions().map((s) => ({
        label: s.label,
        kind: monaco.languages.CompletionItemKind.Function,
        detail: s.detail,
        documentation: s.documentation,
        insertText: s.insertText,
        sortText: s.sortText,
        range,
      }));
      return { suggestions };
    },
  });
}

export { monaco };
