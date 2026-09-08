#!/usr/bin/env node

// Drives the deployed Remote web app against a real desktop TerminalDB on
// this Mac: pairs a browser through the agent that is already running, then
// creates, works in, selects and closes a tab, checking after every step that
// the desktop and the browser agree.
//
// It never touches the TerminalDB the user is working in. It launches its own
// desktop process, restricts every tab command to that process's tabs, and
// quits only that process. On the agent's local socket it behaves as an
// observer: it asks for a pairing link and reads status, and never sends
// inventory, enable or disable, which belong to the real app.

import { execFileSync, spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import net from "node:net";
import { homedir, tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import { chromium } from "playwright";

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1]
    ? process.argv[index + 1]
    : fallback;
}

const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = resolve(scriptDirectory, "../../..");
const appBinary = argument(
  "app",
  resolve(repositoryRoot, "apps/macos/build/TerminalDB.app/Contents/MacOS/TerminalDB"),
);
const remoteDirectory = argument(
  "remote-dir",
  join(homedir(), "Library/Application Support/TerminalDB/Remote"),
);
const headed = process.argv.includes("--headed");
const keepApp = process.argv.includes("--keep-app");

const socketPath = join(remoteDirectory, "agent.sock");
const secretPath = join(remoteDirectory, "agent.secret");
const observerInstanceId = `qa-observer-${crypto.randomUUID()}`;
const marker = `TDB_QA_${Math.random().toString(36).slice(2, 8).toUpperCase()}`;

const steps = [];
let failures = 0;
let client;
let browser;
let qaApp;
let qaDirectory;
let statusFrames = [];
let baselineControllerIds = new Set();
// Keeping the page's own diagnostics makes a failure here explainable
// without a second run.
const pageMessages = [];
let activePage;

function record(name, ok, detail) {
  steps.push({ step: name, ok, detail });
  if (!ok) failures += 1;
  process.stdout.write(`${JSON.stringify({ step: name, ok, detail })}\n`);
}

function check(name, ok, detail) {
  record(name, Boolean(ok), detail);
  if (!ok) throw new Error(`${name} failed: ${detail ?? "no detail"}`);
}

function delay(milliseconds) {
  return new Promise((done) => setTimeout(done, milliseconds));
}

async function waitFor(description, predicate, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  let last;
  while (Date.now() < deadline) {
    try {
      const value = await predicate();
      if (value) return value;
      last = value;
    } catch (error) {
      last = error instanceof Error ? error.message : String(error);
    }
    await delay(150);
  }
  throw new Error(`Timed out waiting for ${description} (last: ${JSON.stringify(last)})`);
}

// --- desktop process inspection (no permissions needed) ---

function processRows() {
  const output = execFileSync("ps", ["-axo", "pid=,ppid=,stat=,command="], {
    encoding: "utf8",
  });
  return output
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const match = /^\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)$/u.exec(line);
      if (!match) return undefined;
      return {
        pid: Number(match[1]),
        parent: Number(match[2]),
        state: match[3],
        command: match[4],
      };
    })
    .filter(Boolean);
}

function childrenOf(pid) {
  return processRows().filter((row) => row.parent === pid);
}

function shellsOf(pid) {
  return childrenOf(pid).filter((row) => row.command.includes("/bin/zsh"));
}

function zombiesOf(pid) {
  return childrenOf(pid).filter((row) => row.state.startsWith("Z"));
}

function descendantsMatching(pid, needle) {
  const rows = processRows();
  const directChildren = rows.filter((row) => row.parent === pid).map((row) => row.pid);
  return rows.filter(
    (row) => directChildren.includes(row.parent) && row.command.includes(needle),
  );
}

// --- agent local socket, as an observer ---

function send(message) {
  client.write(`${JSON.stringify(message)}\n`);
}

function connectObserver() {
  if (!existsSync(socketPath)) {
    throw new Error(
      `No TerminalDB agent socket at ${socketPath}. Enable Remote Control on this Mac first.`,
    );
  }
  const secret = readFileSync(secretPath, "utf8").trim();
  return new Promise((done, fail) => {
    client = net.createConnection(socketPath);
    let buffer = "";
    client.on("data", (value) => {
      buffer += value.toString("utf8");
      let index = buffer.indexOf("\n");
      while (index >= 0) {
        const line = buffer.slice(0, index);
        buffer = buffer.slice(index + 1);
        if (line.trim()) {
          try {
            statusFrames.push(JSON.parse(line));
          } catch {
            // A frame this observer does not understand is not its business.
          }
        }
        index = buffer.indexOf("\n");
      }
    });
    client.on("error", fail);
    client.on("connect", () => {
      send({ type: "hello", secret, instanceId: observerInstanceId });
      done();
    });
  });
}

function latestStatus() {
  return [...statusFrames].reverse().find((frame) => frame.type === "remoteStatus");
}

async function requestPairingURL() {
  const before = await waitFor("the agent's current status", () => latestStatus());
  baselineControllerIds = new Set(
    (before.controllers ?? []).map((controller) => controller.controllerId),
  );
  const stalePairing = before.pairingURL;
  send({ type: "createPairing" });
  // The status carried at hello can hold a spent link from an earlier
  // pairing, so wait for one that is genuinely new.
  const status = await waitFor(
    "a fresh pairing link",
    () => {
      const current = latestStatus();
      if (!current?.pairingURL) return undefined;
      if (current.pairingURL === stalePairing) return undefined;
      return current;
    },
    30_000,
  );
  return status.pairingURL;
}

async function revokeNewControllers() {
  send({ type: "refreshControllers" });
  await delay(1_500);
  const status = latestStatus();
  const added = (status?.controllers ?? []).filter(
    (controller) => !baselineControllerIds.has(controller.controllerId),
  );
  for (const controller of added) {
    send({ type: "revokeController", controllerId: controller.controllerId });
  }
  if (added.length > 0) await delay(1_500);
  return added.length;
}

// --- browser helpers ---

async function readTabs(page) {
  return page.$$eval('[role="tablist"] button[role="tab"]', (nodes) =>
    nodes.map((node, index) => ({
      index,
      title: node.querySelector("strong")?.textContent ?? "",
      directory: node.querySelector("code")?.textContent ?? "",
      selected: node.getAttribute("aria-selected") === "true",
      desktopSelected: node.getAttribute("data-desktop-selected") === "true",
    })),
  );
}

async function qaTabs(page, needle) {
  const tabs = await readTabs(page);
  return tabs.filter((tab) => tab.directory.includes(needle));
}

async function closeControl(page, index) {
  return page.locator(".terminal-tab-close-track .terminal-tab-close").nth(index);
}

async function connectionLabel(page) {
  return page.$eval("button.connection-pill", (node) => node.textContent ?? "").catch(
    () => "",
  );
}

async function run() {
  check("agent socket present", existsSync(socketPath), socketPath);
  check("desktop build present", existsSync(appBinary), appBinary);

  await connectObserver();
  record("observer attached", true, observerInstanceId);

  // A dedicated working directory makes this process's tabs identifiable in a
  // tab strip that also lists the user's own tabs.
  qaDirectory = mkdtempSync(join(tmpdir(), "tdbqa-"));
  const qaNeedle = qaDirectory.split("/").pop();
  qaApp = spawn(appBinary, [], { cwd: qaDirectory, stdio: "ignore" });
  await waitFor(
    "the QA desktop process to open a shell",
    () => shellsOf(qaApp.pid).length >= 1,
    30_000,
  );
  const baselineShells = shellsOf(qaApp.pid).length;
  const baselineZombies = zombiesOf(qaApp.pid).length;
  record("QA desktop process running", true, {
    pid: qaApp.pid,
    directory: qaDirectory,
    shells: baselineShells,
    zombies: baselineZombies,
  });

  const pairingURL = await requestPairingURL();
  check("pairing link issued", pairingURL.includes("/pair/"), pairingURL.split("#")[0]);

  browser = await chromium.launch({ headless: !headed });
  const context = await browser.newContext({
    viewport: { width: 1440, height: 1000 },
    serviceWorkers: "block",
  });
  const page = await context.newPage();
  activePage = page;
  page.on("console", (message) => {
    if (message.type() === "error" || message.type() === "warning") {
      pageMessages.push(`${message.type()}: ${message.text()}`.slice(0, 400));
    }
  });
  page.on("pageerror", (error) => {
    pageMessages.push(`pageerror: ${error.message}`.slice(0, 400));
  });
  page.on("requestfailed", (request) => {
    pageMessages.push(
      `requestfailed: ${request.method()} ${request.url().slice(0, 120)} ${
        request.failure()?.errorText ?? ""
      }`,
    );
  });
  await page.goto(pairingURL, { waitUntil: "domcontentloaded" });

  await waitFor(
    "the pairing fragment to be cleared from the address bar",
    () => !new URL(page.url()).hash,
  );
  record("pairing secret removed from the URL", true, new URL(page.url()).pathname);

  // The tab strip appears as soon as inventory arrives, before the first
  // synchronisation finishes.
  await waitFor("the tab strip", async () => (await readTabs(page)).length > 0, 45_000);
  const allTabs = await readTabs(page);
  const desktopShells = shellsOf(qaApp.pid).length;
  let mine = await qaTabs(page, qaNeedle);
  check(
    "QA process tab visible in the browser",
    mine.length === 1,
    { visible: mine.length, allTabs: allTabs.length, desktopShells },
  );

  // View this run's own tab before waiting to go live. A controller becomes
  // ready once it holds a screen for the tab it is viewing, and the first
  // tab of an unordered inventory would be one of the user's.
  await page.locator('[role="tablist"] button[role="tab"]').nth(mine[0].index).click();
  await waitFor(
    "a live connection",
    async () => (await connectionLabel(page)).includes("LIVE"),
    60_000,
  );
  record("connection live", true, await connectionLabel(page));
  mine = await qaTabs(page, qaNeedle);

  // The sole tab of a desktop process cannot be closed remotely, because that
  // would quit TerminalDB there.
  const soleClose = await closeControl(page, mine[0].index);
  const soleDisabled = await soleClose.isDisabled();
  const soleReason = await soleClose.getAttribute("title");
  check(
    "last tab is not closable from the browser",
    soleDisabled && (soleReason ?? "").includes("last tab"),
    { disabled: soleDisabled, reason: soleReason },
  );

  await waitFor("the QA tab to be selected", async () => {
    const tabs = await qaTabs(page, qaNeedle);
    return tabs.length > 0 && tabs.every((tab) => tab.selected);
  });
  record("QA tab selected", true, mine[0].title);

  const createdAt = Date.now();
  await page.locator("button.terminal-new-tab").click();
  const grown = await waitFor(
    "a second QA tab",
    async () => {
      const tabs = await qaTabs(page, qaNeedle);
      return tabs.length === 2 ? tabs : undefined;
    },
    20_000,
  );
  record("tab created from the browser", true, {
    milliseconds: Date.now() - createdAt,
    tabs: grown.map((tab) => tab.title),
  });
  await waitFor(
    "a new shell on the desktop",
    () => shellsOf(qaApp.pid).length === desktopShells + 1,
    15_000,
  );
  record("desktop opened a real shell", true, {
    shells: shellsOf(qaApp.pid).length,
  });

  const created = (await qaTabs(page, qaNeedle)).find((tab) => tab.selected);
  check("new tab is selected in the browser", Boolean(created), created?.title);

  // Work in it, and prove the desktop really ran the command.
  await page.locator(".terminal-pane.active .xterm-helper-textarea").focus();
  const commandAt = Date.now();
  await page.keyboard.type(`sleep 6 && printf '${marker}\\n'`);
  await page.keyboard.press("Enter");

  await waitFor(
    "the desktop to start the command",
    () => descendantsMatching(qaApp.pid, "sleep 6").length >= 1,
    15_000,
  );
  record("desktop executed browser input", true, {
    milliseconds: Date.now() - commandAt,
  });

  // A tab running a foreground process must report busy, which is what
  // disables its close button. Measure how long that takes to arrive.
  const busyAt = Date.now();
  const busyReason = await waitFor(
    "the browser to see the tab as busy",
    async () => {
      const tabs = await qaTabs(page, qaNeedle);
      const target = tabs.find((tab) => tab.selected);
      if (!target) return undefined;
      const control = await closeControl(page, target.index);
      const title = await control.getAttribute("title");
      return (title ?? "").includes("foreground process") ? title : undefined;
    },
    15_000,
  );
  record("busy state reached the browser", true, {
    milliseconds: Date.now() - busyAt,
    reason: busyReason,
  });

  await waitFor(
    "the command output in the browser",
    async () => {
      const text = await page
        .locator(".terminal-pane.active .xterm-rows")
        .innerText()
        .catch(() => "");
      return text.includes(marker);
    },
    30_000,
  );
  record("output rendered in the browser", true, marker);

  // Selection round trip across two tabs of the same desktop process.
  const pair = await qaTabs(page, qaNeedle);
  const other = pair.find((tab) => !tab.selected);
  check("a second QA tab to switch to", Boolean(other), pair.length);
  await page.locator('[role="tablist"] button[role="tab"]').nth(other.index).click();
  await waitFor("the other QA tab to be selected", async () => {
    const tabs = await qaTabs(page, qaNeedle);
    const target = tabs.find((tab) => tab.directory === other.directory);
    return target?.selected;
  });
  record("tab selection followed the browser", true, other.title);

  // The desktop reports which of its tabs is in front, independently of what
  // this browser is viewing.
  const marked = (await qaTabs(page, qaNeedle)).filter((tab) => tab.desktopSelected);
  record("desktop selection reported", marked.length >= 1, {
    marked: marked.length,
  });

  // Close the tab this run created, and only that one.
  const closable = await waitFor(
    "the created tab to become idle",
    async () => {
      const tabs = await qaTabs(page, qaNeedle);
      const target = tabs.find((tab) => tab.title === created.title || tab.index === created.index);
      if (!target) return undefined;
      const control = await closeControl(page, target.index);
      return (await control.isDisabled()) ? undefined : target;
    },
    30_000,
  );
  const zombiesBeforeClose = zombiesOf(qaApp.pid).length;
  const shellsBeforeClose = shellsOf(qaApp.pid).length;
  const closedAt = Date.now();
  await (await closeControl(page, closable.index)).click();
  await waitFor(
    "the tab to leave the strip",
    async () => (await qaTabs(page, qaNeedle)).length === 1,
    20_000,
  );
  record("tab closed from the browser", true, {
    milliseconds: Date.now() - closedAt,
  });
  await waitFor(
    "the desktop shell to exit",
    () => shellsOf(qaApp.pid).length === shellsBeforeClose - 1,
    15_000,
  );
  await delay(1_500);
  const zombiesAfterClose = zombiesOf(qaApp.pid).length;
  check(
    "closed tab left no unreaped process",
    zombiesAfterClose <= zombiesBeforeClose,
    { before: zombiesBeforeClose, after: zombiesAfterClose },
  );

  // A shell that ends on its own closes its tab and leaves nothing behind.
  await page.locator("button.terminal-new-tab").click();
  const forExit = await waitFor(
    "a tab to end by exiting its shell",
    async () => {
      const tabs = await qaTabs(page, qaNeedle);
      return tabs.length === 2 ? tabs.find((tab) => tab.selected) : undefined;
    },
    20_000,
  );
  const zombiesBeforeExit = zombiesOf(qaApp.pid).length;
  await page.locator(".terminal-pane.active .xterm-helper-textarea").focus();
  await page.keyboard.type("exit");
  await page.keyboard.press("Enter");
  await waitFor(
    "the exited tab to leave the strip",
    async () => (await qaTabs(page, qaNeedle)).length === 1,
    20_000,
  );
  await delay(1_500);
  check(
    "exited shell closed its tab and was reaped",
    zombiesOf(qaApp.pid).length <= zombiesBeforeExit,
    {
      tab: forExit.title,
      zombiesBefore: zombiesBeforeExit,
      zombiesAfter: zombiesOf(qaApp.pid).length,
      shells: shellsOf(qaApp.pid).length,
    },
  );

  // Typing still works after all of that, which is what a rejected tab
  // command used to break.
  const label = await connectionLabel(page);
  check("connection still live at the end", label.includes("LIVE"), label);
}

async function cleanup() {
  try {
    if (browser) await browser.close();
  } catch {
    // A closed browser is the goal either way.
  }
  try {
    if (client) {
      const revoked = await revokeNewControllers();
      record("controllers revoked", true, { revoked });
      client.end();
    }
  } catch (error) {
    record("controllers revoked", false, error instanceof Error ? error.message : error);
  }
  try {
    if (qaApp && !keepApp) {
      qaApp.kill("SIGTERM");
      await delay(1_500);
      if (shellsOf(qaApp.pid).length > 0) qaApp.kill("SIGKILL");
      record("QA desktop process stopped", true, { pid: qaApp.pid });
    }
  } catch (error) {
    record("QA desktop process stopped", false, error instanceof Error ? error.message : error);
  }
  if (qaDirectory) rmSync(qaDirectory, { recursive: true, force: true });
}

try {
  await run();
} catch (error) {
  let visible = "";
  let location = "";
  try {
    visible = (await activePage?.locator("body").innerText())?.slice(0, 700) ?? "";
    location = activePage?.url() ?? "";
  } catch {
    // The page may already be gone.
  }
  record("run", false, {
    error: error instanceof Error ? error.message : String(error),
    url: location,
    visible,
    pageMessages: pageMessages.slice(-12),
  });
} finally {
  await cleanup();
  const failed = steps.filter((step) => !step.ok);
  process.stdout.write(
    `\n${steps.length - failed.length}/${steps.length} checks passed\n`,
  );
  for (const step of failed) {
    process.stdout.write(`FAILED ${step.step}: ${JSON.stringify(step.detail)}\n`);
  }
  process.exit(failures > 0 ? 1 : 0);
}
