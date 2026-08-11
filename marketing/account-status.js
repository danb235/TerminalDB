"use strict";

(() => {
  const APP_ORIGIN = "https://app.terminaldb.app";
  const STATUS_MESSAGE = "terminaldb-account-status-v1";
  const STATUS_REQUEST = "terminaldb-account-status-request-v1";

  let readyAttempts = 0;
  const ready = () => {
    const root = document.querySelector("#dc-root [data-terminaldb-account]");
    const frame = document.getElementById("terminaldb-account-status-frame");
    if (!(root instanceof HTMLElement) || !(frame instanceof HTMLIFrameElement)) {
      readyAttempts += 1;
      if (readyAttempts < 60) window.setTimeout(ready, 50);
      return;
    }

    const checking = root.querySelector("[data-account-checking]");
    const signedOut = root.querySelector("[data-account-signed-out]");
    const signedIn = root.querySelector("[data-account-signed-in]");
    const username = root.querySelector("[data-account-username]");
    let resolved = false;

    const showSignedOut = () => {
      resolved = true;
      checking?.setAttribute("hidden", "");
      signedIn?.setAttribute("hidden", "");
      signedOut?.removeAttribute("hidden");
      root.dataset.state = "signed-out";
    };

    const showSignedIn = (name) => {
      resolved = true;
      checking?.setAttribute("hidden", "");
      signedOut?.setAttribute("hidden", "");
      signedIn?.removeAttribute("hidden");
      if (username) username.textContent = name || "TerminalDB user";
      root.dataset.state = "signed-in";
    };

    const requestStatus = () => {
      frame.contentWindow?.postMessage({ type: STATUS_REQUEST }, APP_ORIGIN);
    };

    window.addEventListener("message", (event) => {
      if (
        event.origin !== APP_ORIGIN ||
        event.source !== frame.contentWindow ||
        !event.data ||
        event.data.type !== STATUS_MESSAGE
      ) {
        return;
      }
      if (event.data.signedIn === true) showSignedIn(event.data.username);
      else showSignedOut();
    });
    frame.addEventListener("load", requestStatus);
    window.addEventListener("focus", requestStatus);
    document.addEventListener("visibilitychange", () => {
      if (document.visibilityState === "visible") requestStatus();
    });
    window.setTimeout(() => {
      if (!resolved) showSignedOut();
    }, 4_000);
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", () => window.setTimeout(ready, 0));
  } else {
    window.setTimeout(ready, 0);
  }
})();
