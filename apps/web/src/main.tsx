import React from "react";
import { createRoot } from "react-dom/client";

import "@terminaldb/design-system/styles.css";
import "@xterm/xterm/css/xterm.css";
import "./remote.css";
import { App } from "./App";

if ("serviceWorker" in navigator && !import.meta.env.DEV) {
  window.addEventListener("load", () => {
    void navigator.serviceWorker.register("/sw.js");
  });
}

createRoot(document.getElementById("root")!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
