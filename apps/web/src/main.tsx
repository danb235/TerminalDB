import React from "react";
import { createRoot } from "react-dom/client";

import "@terminaldb/design-system/styles.css";
import "@xterm/xterm/css/xterm.css";
import "./remote.css";
import { App } from "./App";
import { AppErrorBoundary } from "./AppErrorBoundary";

if (!import.meta.env.DEV) {
  // Remote control requires a live connection. Offline shell caching can only
  // create mixed-version deployments, so remove registrations created by
  // earlier releases and let HTTP caching follow the deployment policy.
  if ("serviceWorker" in navigator) {
    void navigator.serviceWorker.getRegistrations()
      .then((registrations) => Promise.all(registrations.map((registration) => registration.unregister())))
      .catch(() => undefined);
  }
  if ("caches" in window) {
    void caches.keys()
      .then((keys) => Promise.all(keys
        .filter((key) => key.startsWith("terminaldb-shell-"))
        .map((key) => caches.delete(key))))
      .catch(() => undefined);
  }
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <AppErrorBoundary>
      <App />
    </AppErrorBoundary>
  </React.StrictMode>,
);
