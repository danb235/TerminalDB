#!/usr/bin/env node

import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { chromium } from "playwright";

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1]
    ? process.argv[index + 1]
    : fallback;
}

const profile = argument("profile", "stelao");
const region = argument("region", "us-west-2");
const baseURL = argument("base-url", "https://dwi1gx38gzrsl.cloudfront.net");
const functionName = argument("function-name", "terminaldb-remote-dev-control");
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const liveMacPath = resolve(scriptDirectory, "live-mac.mjs");

let harness;
let browser;
let ready;
let stderr = "";

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

async function waitFor(description, predicate, timeout = 30_000) {
  const deadline = Date.now() + timeout;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const value = await predicate();
      if (value) return value;
    } catch (error) {
      lastError = error;
    }
    await delay(100);
  }
  throw new Error(
    `Timed out waiting for ${description}${lastError instanceof Error ? `: ${lastError.message}` : ""}`,
  );
}

function readEvents() {
  if (!ready?.eventsFile || !existsSync(ready.eventsFile)) return [];
  return readFileSync(ready.eventsFile, "utf8")
    .split(/\r?\n/u)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function commandCount(input) {
  return readEvents().filter(
    (event) => event.type === "remote-command" && event.input === input,
  ).length;
}

function terminalInputStream() {
  return readEvents()
    .filter((event) => event.type === "remote-command" && event.route === "pty.input")
    .map((event) => event.input ?? "")
    .join("");
}

function streamOccurrenceCount(input) {
  if (!input) return 0;
  return terminalInputStream().split(input).length - 1;
}

function routeCount(route) {
  return readEvents().filter(
    (event) => event.type === "remote-command" && event.route === route,
  ).length;
}

function commandDiagnostics() {
  return readEvents()
    .filter((event) => event.type === "remote-command")
    .map((event) => ({
      route: event.route,
      inputLength: typeof event.input === "string" ? event.input.length : 0,
      hasAccount: typeof event.accountId === "string" && event.accountId.length > 0,
    }));
}

async function waitForLive(page, timeout = 30_000) {
  await page.getByRole("button", { name: /^LIVE\./u }).waitFor({ timeout });
}

async function waitForStableLive(page, stableMilliseconds = 750, timeout = 30_000) {
  let liveSince;
  await waitFor(
    "stable LIVE browser state",
    async () => {
      const label = await page.locator(".connection-pill").innerText();
      if (label !== "LIVE") {
        liveSince = undefined;
        return false;
      }
      liveSince ??= Date.now();
      return Date.now() - liveSince >= stableMilliseconds;
    },
    timeout,
  );
}

async function main() {
  harness = spawn(
    process.execPath,
    [
      liveMacPath,
      "--profile",
      profile,
      "--region",
      region,
      "--base-url",
      baseURL,
      "--function-name",
      functionName,
    ],
    { stdio: ["pipe", "pipe", "pipe"] },
  );
  let stdout = "";
  harness.stdout.setEncoding("utf8");
  harness.stdout.on("data", (chunk) => {
    stdout += chunk;
    for (;;) {
      const newline = stdout.indexOf("\n");
      if (newline < 0) break;
      const line = stdout.slice(0, newline);
      stdout = stdout.slice(newline + 1);
      if (!line) continue;
      const event = JSON.parse(line);
      if (event.event === "ready") ready = event;
    }
  });
  harness.stderr.setEncoding("utf8");
  harness.stderr.on("data", (chunk) => {
    stderr += chunk;
  });
  await waitFor("native Mac browser-test pairing", () => ready, 30_000);

  const pairingURL = readFileSync(ready.pairingFile, "utf8").trim();
  if (!pairingURL.startsWith(`${baseURL}/pair/`) || !pairingURL.includes("#")) {
    throw new Error("Native Mac returned an invalid production pairing URL");
  }

  browser = await chromium.launch({ headless: true });
  const context = await browser.newContext({
    viewport: { width: 390, height: 844 },
    deviceScaleFactor: 3,
    hasTouch: true,
    isMobile: true,
    serviceWorkers: "block",
  });
  const page = await context.newPage();
  const pageErrors = [];
  page.on("pageerror", (error) => pageErrors.push(error.message));

  await page.addInitScript({
    content: `
      (() => {
        const nativeSetTimeout = window.setTimeout.bind(window);
        let rotationAccelerated = false;
        window.setTimeout = (handler, timeout = 0, ...args) => {
          if (timeout === 110 * 60 * 1000 && !rotationAccelerated) {
            rotationAccelerated = true;
            return nativeSetTimeout(handler, 6000, ...args);
          }
          return nativeSetTimeout(handler, timeout, ...args);
        };
        window.__terminaldbOnline = true;
        try {
          Object.defineProperty(Navigator.prototype, "onLine", {
            configurable: true,
            get: () => window.__terminaldbOnline,
          });
        } catch {}
        const NativeWebSocket = window.WebSocket;
        window.__terminaldbSockets = [];
        window.WebSocket = class extends NativeWebSocket {
          constructor(...args) {
            super(...args);
            window.__terminaldbSockets.push(this);
          }
        };
      })();
    `,
  });

  await page.goto(pairingURL, { waitUntil: "domcontentloaded" });
  if ((await page.locator("body").innerText()).includes(new URL(pairingURL).hash.slice(1))) {
    throw new Error("Pairing secret appeared in visible browser content");
  }
  await page.waitForURL(`${baseURL}/remote`, { timeout: 30_000 });
  if (new URL(page.url()).hash) throw new Error("Pairing fragment remained in browser history");
  await page.locator(".terminal-pane.active .xterm-helper-textarea")
    .waitFor({ timeout: 30_000 });
  await waitForLive(page);
  const browserGeometry = await page.locator(".terminal-pane.active .xterm-host")
    .evaluate((element) => ({
      columns: Number(element.dataset.columns),
      rows: Number(element.dataset.rows),
    }));
  await waitFor(
    "browser PTY geometry negotiation",
    () => readEvents().find(
      (event) => event.type === "resize" &&
        event.active === true &&
        event.columns === browserGeometry.columns &&
        event.rows === browserGeometry.rows,
    ),
  );

  const keyProtection = await page.evaluate(async () => {
    const database = await new Promise((resolveDatabase, rejectDatabase) => {
      const request = indexedDB.open("terminaldb-remote", 1);
      request.onsuccess = () => resolveDatabase(request.result);
      request.onerror = () => rejectDatabase(request.error);
    });
    const read = (key) => new Promise((resolveRecord, rejectRecord) => {
      const transaction = database.transaction("keys", "readonly");
      const request = transaction.objectStore("keys").get(key);
      request.onsuccess = () => resolveRecord(request.result);
      request.onerror = () => rejectRecord(request.error);
    });
    const identity = await read("controller-identity-v1");
    const session = await read("controller-session-v1");
    database.close();
    return {
      signingPrivate: identity?.signingPrivateKey?.extractable,
      agreementPrivate: identity?.agreementPrivateKey?.extractable,
      sendKey: session?.sendKey?.extractable,
      receiveKey: session?.receiveKey?.extractable,
    };
  });
  if (Object.values(keyProtection).some((extractable) => extractable !== false)) {
    throw new Error(`Browser persisted an extractable key: ${JSON.stringify(keyProtection)}`);
  }

  await page.evaluate(() => {
    window.__terminaldbConnectionStates = [];
    const capture = () => {
      const state = document.querySelector(".connection-pill")?.textContent?.trim();
      if (state && !window.__terminaldbConnectionStates.includes(state)) {
        window.__terminaldbConnectionStates.push(state);
      }
    };
    const observer = new MutationObserver(capture);
    observer.observe(document.body, { subtree: true, childList: true, characterData: true });
    capture();
  });
  await waitFor(
    "browser make-before-break rotation",
    () => page.evaluate(
      () => window.__terminaldbConnectionStates.includes("ROTATING CONNECTION") ||
        window.__terminaldbSockets.length >= 2,
    ),
    15_000,
  );
  await waitForLive(page);
  const socketCountAfterRotation = await page.evaluate(
    () => window.__terminaldbSockets.length,
  );
  if (socketCountAfterRotation < 2) {
    throw new Error("Browser rotation did not open a replacement WebSocket");
  }

  const terminalKeyboard = page.locator(
    ".terminal-pane.active .xterm-helper-textarea",
  );
  await terminalKeyboard.waitFor();
  const terminalInput = "printf browser-live-qa";
  const terminalWireInput = `${terminalInput}\r`;
  await terminalKeyboard.focus();
  const terminalStartedAt = performance.now();
  await page.keyboard.type(terminalInput);
  await page.keyboard.press("Enter");
  try {
    await waitFor("browser terminal command", () => streamOccurrenceCount(terminalWireInput) === 1);
  } catch (error) {
    throw new Error(
      `${error.message}; stream=${JSON.stringify(terminalInputStream())}; commands=${JSON.stringify(commandDiagnostics())}`,
    );
  }
  await waitFor(
    "browser terminal output",
    async () => (await page.locator(".terminal-pane.active .xterm-rows").innerText())
      .includes(`executed: ${terminalInput}`),
  );
  const terminalRoundTripMs = Math.round(performance.now() - terminalStartedAt);

  const slowInputStartedAt = performance.now();
  for (const character of "pwd") {
    await page.keyboard.type(character);
    await delay(230);
  }
  await page.keyboard.press("Enter");
  await waitFor(
    "ordered slow terminal command",
    () => terminalInputStream().endsWith("pwd\r"),
  );
  await waitFor(
    "ordered slow terminal output",
    () => readEvents().some(
      (event) => event.type === "executed-command" && event.command === "pwd",
    ),
  );
  const slowInputRoundTripMs = Math.round(performance.now() - slowInputStartedAt);

  await terminalKeyboard.focus();
  for (let index = 0; index < 6; index += 1) {
    await page.keyboard.press("Backspace");
  }
  await delay(250);
  await page.keyboard.type("pwd");
  for (let index = 0; index < 6; index += 1) {
    await page.keyboard.press("Backspace");
  }
  await page.keyboard.press("Enter");
  await waitFor(
    "prompt-bounded Backspace command",
    () => readEvents().some(
      (event) => event.type === "executed-command" && event.command === "",
    ),
  );
  const editableCellsAfterBoundary = await page
    .locator(".terminal-pane.active .xterm-host")
    .getAttribute("data-editable-cells");
  if (editableCellsAfterBoundary !== "0") {
    throw new Error(`Backspace escaped its optimistic boundary (${editableCellsAfterBoundary})`);
  }

  await terminalKeyboard.focus();
  await page.keyboard.press("ArrowUp");
  await waitFor(
    "browser shell history key",
    () => terminalInputStream().endsWith("\u001b[A"),
  );

  const ctrlC = "\u0003";
  await waitForStableLive(page);
  await terminalKeyboard.focus();
  await page.keyboard.press("Control+c");
  try {
    await waitFor("confirmed Ctrl-C", () => commandCount(ctrlC) === 1, 10_000);
  } catch (error) {
    const connectionState = await page.locator(".connection-pill").innerText().catch(() => "missing");
    throw new Error(
      `${error.message}; connection=${connectionState}; commands=${JSON.stringify(commandDiagnostics())}`,
    );
  }

  await page.getByRole("button", { name: "Claude account" }).click();
  const secondary = page.locator("article.account-card").filter({
    hasText: "secondary@example.invalid",
  });
  await secondary.getByRole("button", { name: "Use on this tab" }).click();
  await waitFor(
    "browser Claude account switch",
    () => readEvents().some(
      (event) => event.type === "remote-command" &&
        event.route === "account.switch" &&
        event.accountId === "account-secondary",
    ),
  );
  await secondary.getByRole("button", { name: "Active on this tab" }).waitFor();
  const usageCount = routeCount("usage.refresh");
  await page.getByRole("button", { name: "Refresh usage" }).click();
  await waitFor("browser usage refresh", () => routeCount("usage.refresh") === usageCount + 1);

  await page.getByRole("button", { name: "Close panel" }).click();
  const terminalBeforeMacPause = await page
    .locator(".terminal-pane.active .xterm-rows")
    .innerText();
  const inputBeforeMacPause = terminalInputStream();
  harness.stdin.write("pause-agent\n");
  await waitFor(
    "native agent pause",
    () => readEvents().some((event) => event.type === "agent-paused"),
  );
  await page.getByRole("button", { name: /^MAC OFFLINE\./u })
    .waitFor({ timeout: 70_000 });
  await terminalKeyboard.focus();
  await page.keyboard.type("printf mac-offline-must-not-send");
  await page.keyboard.press("Enter");
  await delay(250);
  if (terminalInputStream() !== inputBeforeMacPause) {
    throw new Error("Terminal accepted input while the Mac was unavailable");
  }
  if (!(await page.locator(".terminal-pane.active .xterm-rows").innerText()).includes(
    terminalBeforeMacPause.trim(),
  )) {
    throw new Error("The browser discarded the last terminal viewport while the Mac was unavailable");
  }
  const alternateSession = page.getByRole("tab").nth(1);
  if (await alternateSession.isVisible()) {
    await alternateSession.click();
    await page.getByRole("button", { name: /^MAC OFFLINE\./u })
      .waitFor({ timeout: 2_000 });
  }
  harness.stdin.write("resume-agent\n");
  await waitFor(
    "native agent resume",
    () => readEvents().some((event) => event.type === "agent-resumed"),
  );
  await waitForLive(page, 30_000);
  if (terminalInputStream() !== inputBeforeMacPause) {
    throw new Error("Recovery sent input entered while the Mac was unavailable");
  }

  const blockedInput = "printf offline-must-not-send";
  const inputBeforeOffline = terminalInputStream();
  await page.evaluate(() => {
    window.__terminaldbOnline = false;
    const socket = [...window.__terminaldbSockets]
      .reverse()
      .find((candidate) => candidate.readyState === WebSocket.OPEN);
    socket?.close(4001, "Browser offline QA");
  });
  await page.getByRole("button", { name: /^PHONE OFFLINE\./u }).waitFor({ timeout: 10_000 });
  await terminalKeyboard.focus();
  await page.keyboard.type(blockedInput);
  await page.keyboard.press("Enter");
  await delay(250);
  if (terminalInputStream() !== inputBeforeOffline) {
    throw new Error("Terminal accepted input while the browser was offline");
  }
  await page.evaluate(() => {
    window.__terminaldbOnline = true;
    window.dispatchEvent(new Event("online"));
  });
  await waitForLive(page, 30_000);
  if (terminalInputStream() !== inputBeforeOffline) {
    throw new Error("Reconnect sent input entered while offline");
  }

  await page.reload({ waitUntil: "domcontentloaded" });
  await page.locator(".terminal-pane.active .xterm-helper-textarea")
    .waitFor({ timeout: 30_000 });
  await waitForLive(page);
  if (terminalInputStream() !== inputBeforeOffline) throw new Error("Reload resent terminal input");

  await page.getByRole("button", { name: "Remote controls" }).click();
  await page.getByRole("button", { name: "Revoke this browser" }).click();
  await page.getByRole("button", { name: /^REVOKED\./u }).waitFor({ timeout: 15_000 });
  await page.reload({ waitUntil: "domcontentloaded" });
  await page.getByRole("heading", { name: "Pair from your Mac" }).waitFor({ timeout: 15_000 });

  if (pageErrors.length > 0) {
    throw new Error(`Browser page errors: ${pageErrors.join(" | ")}`);
  }
  const result = {
    success: true,
    pairedAndFragmentRemoved: true,
    nonExtractableBrowserKeys: true,
    browserMakeBeforeBreakRotation: socketCountAfterRotation >= 2,
    terminalInputExactlyOnce: streamOccurrenceCount(terminalWireInput) === 1,
    terminalRoundTripMs,
    slowInputRoundTripMs,
    slowInputOrdered: terminalInputStream().includes("pwd\r"),
    promptBoundaryProtected: editableCellsAfterBoundary === "0",
    ptyGeometryNegotiated: true,
    shellHistoryKey: terminalInputStream().includes("\u001b[A"),
    deliberateCtrlC: commandCount(ctrlC) === 1,
    claudeAccountSwitched: readEvents().some(
      (event) => event.route === "account.switch" && event.accountId === "account-secondary",
    ),
    usageRefreshed: routeCount("usage.refresh") > usageCount,
    offlineInputBlocked: !terminalInputStream().includes(blockedInput),
    macPauseInputBlocked: !terminalInputStream().includes("mac-offline-must-not-send"),
    macPausePreservedViewport: true,
    macPauseRecovered: true,
    reloadReconnected: true,
    revokedControllerForgotten: true,
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

try {
  await main();
} catch (error) {
  if (stderr) process.stderr.write(stderr);
  throw error;
} finally {
  await browser?.close().catch(() => undefined);
  if (harness && harness.exitCode === null) {
    harness.stdin.write("disable\n");
    await delay(2_500);
    harness.kill("SIGTERM");
  }
}
