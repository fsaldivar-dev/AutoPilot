import React from "react";
import ReactDOM from "react-dom/client";
import { AppShell } from "./app/AppShell";
import { useStore } from "./state/store";
import "./composer.css";

// Expose the store in dev mode so human-sim / E2E tests can seed state.
if (import.meta.env.DEV) {
  (window as unknown as { __store__: typeof useStore }).__store__ = useStore;
}

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <AppShell />
  </React.StrictMode>
);
