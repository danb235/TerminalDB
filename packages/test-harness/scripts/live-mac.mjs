#!/usr/bin/env node

import { execFileSync, spawn } from "node:child_process";
import {
  appendFileSync,
  chmodSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import net from "node:net";
import { tmpdir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

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
const rotationSeconds = argument("rotation-seconds", "");
const scriptDirectory = dirname(fileURLToPath(import.meta.url));
const agentPath = resolve(
  scriptDirectory,
  "../../../apps/macos/build/TerminalDB.app/Contents/MacOS/TerminalDBRemoteAgent",
);
const stateDirectory = mkdtempSync(join(tmpdir(), "terminaldb-live-agent-"));
const responsePath = join(stateDirectory, "enrollment-response.json");
const pairingPath = join(stateDirectory, "pairing-url");
const eventsPath = join(stateDirectory, "events.jsonl");
const socketPath = join(stateDirectory, "agent.sock");
const secretPath = join(stateDirectory, "agent.secret");

if (!existsSync(agentPath)) {
  throw new Error(`Build the native application before live QA: ${agentPath}`);
}

function aws(...args) {
  return execFileSync(
    "aws",
    [...args, "--profile", profile, "--region", region],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
  ).trim();
}

aws(
  "lambda",
  "invoke",
  "--function-name",
  functionName,
  "--cli-binary-format",
  "raw-in-base64-out",
  "--payload",
  '{"action":"createEnrollment"}',
  responsePath,
  "--query",
  "StatusCode",
  "--output",
  "text",
);
const enrollment = JSON.parse(readFileSync(responsePath, "utf8"));
if (typeof enrollment.enrollmentCode !== "string") {
  throw new Error("The enrollment Lambda did not return a one-time code");
}

const agent = spawn(agentPath, [], {
  env: {
    ...process.env,
    TERMINALDB_REMOTE_EPHEMERAL_IDENTITY: "1",
    TERMINALDB_REMOTE_DEVICE_NAME: "TerminalDB Live QA Mac",
    TERMINALDB_REMOTE_STATE_DIR: stateDirectory,
    ...(rotationSeconds
      ? { TERMINALDB_REMOTE_ROTATION_SECONDS: rotationSeconds }
      : {}),
  },
  stdio: ["ignore", "pipe", "pipe"],
});
let client;
let buffer = "";
let stopped = false;
let remoteDisabled = false;
let currentAccount = "account-primary";
let dropNextAcknowledgement = false;
let terminalInputBuffer = "";
let previousTerminalCommand = "";
let terminalViewport = "TerminalDB live E2E ready\r\nqa@terminaldb % ";
let terminalRows = 24;
let terminalColumns = 80;
const acceptedRequests = new Map();
let lastPairingURL;
let pairingRevision = 0;

function appendEvent(value) {
  appendFileSync(eventsPath, `${JSON.stringify({ at: Date.now(), ...value })}\n`, {
    mode: 0o600,
  });
}

function send(value) {
  client?.write(`${JSON.stringify(value)}\n`);
}

function inventory() {
  const updatedAt = new Date().toISOString();
  return {
    id: "instance-live-qa",
    name: "TerminalDB QA",
    host: "QA Mac",
    accounts: [
      {
        id: "account-primary",
        label: "Primary",
        email: "primary@example.invalid",
        plan: "Max",
        signedIn: true,
        usage: [
          { label: "5h", utilization: 18, resetsAt: "in 3h" },
          { label: "7d", utilization: 31, resetsAt: "Monday" },
          { label: "Fable", utilization: 7 },
        ],
      },
      {
        id: "account-secondary",
        label: "Secondary",
        email: "secondary@example.invalid",
        plan: "Pro",
        signedIn: true,
        usage: [
          { label: "5h", utilization: 4, resetsAt: "in 4h" },
          { label: "7d", utilization: 12, resetsAt: "Tuesday" },
          { label: "Fable", utilization: 0 },
        ],
      },
    ],
    tabs: [
      {
        id: "tab-live-claude",
        instanceId: "instance-live-qa",
        windowId: "window-live-1",
        title: "Claude permission review",
        directory: "/Users/qa/TerminalDB",
        environment: "LOCAL",
        accountId: currentAccount,
        accountLabel: currentAccount === "account-primary" ? "Primary" : "Secondary",
        foregroundProcess: "claude",
        inputMode: "application",
        busy: false,
        claudeState: "attention",
        updatedAt,
      },
      {
        id: "tab-live-busy",
        instanceId: "instance-live-qa",
        windowId: "window-live-1",
        title: "Build logs",
        directory: "/Users/qa/TerminalDB",
        environment: "LOCAL",
        accountId: "account-primary",
        accountLabel: "Primary",
        foregroundProcess: "npm test",
        busy: true,
        claudeState: "working",
        updatedAt,
      },
    ],
  };
}

function handle(message) {
  if (message.type === "remoteStatus") {
    remoteDisabled = message.state === "disabled" && message.enabled === false;
    appendEvent({
      type: "status",
      state: message.state,
      enabled: message.enabled,
      controllerCount: Array.isArray(message.controllers)
        ? message.controllers.length
        : 0,
    });
    if (message.pairingURL && message.pairingURL !== lastPairingURL) {
      lastPairingURL = message.pairingURL;
      pairingRevision += 1;
      appendEvent({ type: "pairing-updated", revision: pairingRevision });
    }
    if (message.pairingURL && !existsSync(pairingPath)) {
      writeFileSync(pairingPath, message.pairingURL, { mode: 0o600 });
      chmodSync(pairingPath, 0o600);
      process.stdout.write(
        `${JSON.stringify({
          event: "ready",
          pairingFile: pairingPath,
          eventsFile: eventsPath,
          stateDirectory,
        })}\n`,
      );
    }
    return;
  }
  if (message.type === "snapshotRequest") {
    appendEvent({
      type: "snapshot-request",
      tabId: message.tabId,
      controllerId: message.controllerId,
    });
    send({
      type: "snapshot",
      tabId: message.tabId,
      controllerId: message.controllerId,
      text: terminalViewport,
      rows: terminalRows,
      columns: terminalColumns,
    });
    return;
  }
  if (message.type === "resize") {
    appendEvent({
      type: "resize",
      tabId: message.tabId,
      controllerId: message.controllerId,
      columns: message.columns,
      rows: message.rows,
      active: message.active,
    });
    if (message.active !== false) {
      terminalColumns = message.columns;
      terminalRows = message.rows;
      send({
        type: "snapshot",
        tabId: message.tabId,
        controllerId: message.controllerId,
        text: terminalViewport,
        rows: terminalRows,
        columns: terminalColumns,
        inputMode: "application",
      });
    }
    return;
  }
  if (message.type === "remoteCommand") {
    appendEvent({
      type: "remote-command",
      route: message.route,
      tabId: message.tabId,
      input: message.input,
      accountId: message.accountId,
      requestId: message.requestId,
    });
    const acknowledgement = {
      type: "ack",
      controllerId: message.controllerId,
      requestId: message.requestId,
      accepted: true,
      detail: "Accepted by the live Mac harness",
    };
    acceptedRequests.set(message.requestId, acknowledgement);
    if (dropNextAcknowledgement) {
      dropNextAcknowledgement = false;
      appendEvent({ type: "ack-dropped", requestId: message.requestId });
    } else {
      send(acknowledgement);
    }
    if (message.route === "pty.input") {
      let terminalUpdate = "";
      if (message.input === "\u0003") {
        terminalInputBuffer = "";
        terminalUpdate = "^C\r\nqa@terminaldb % ";
      } else if (message.input === "\u001b[A") {
        terminalInputBuffer = previousTerminalCommand;
        terminalUpdate = `\r\u001b[2Kqa@terminaldb % ${terminalInputBuffer}`;
      } else {
        for (const character of message.input) {
          if (character === "\b" || character === "\x7f") {
            terminalInputBuffer = Array.from(terminalInputBuffer)
              .slice(0, -1)
              .join("");
            terminalUpdate +=
              `\r\u001b[2Kqa@terminaldb % ${terminalInputBuffer}`;
          } else if (character === "\r" || character === "\n") {
            const command = terminalInputBuffer;
            previousTerminalCommand = command;
            terminalInputBuffer = "";
            appendEvent({ type: "executed-command", command });
            terminalUpdate +=
              `\r\nexecuted: ${command}\r\nqa@terminaldb % `;
          } else {
            terminalInputBuffer += character;
            terminalUpdate += character;
          }
        }
      }
      terminalViewport += terminalUpdate;
      send({
        type: "output",
        tabId: message.tabId,
        text: terminalUpdate,
        rows: terminalRows,
        columns: terminalColumns,
        inputMode: "application",
      });
    } else if (message.route === "account.switch") {
      currentAccount = message.accountId;
      send({ type: "inventory", instance: inventory() });
    } else if (message.route === "usage.refresh") {
      send({ type: "inventory", instance: inventory() });
    }
    return;
  }
  if (message.type === "ackStatusRequest") {
    const acknowledgement = acceptedRequests.get(message.requestId) ?? {
      type: "ack",
      controllerId: message.controllerId,
      requestId: message.requestId,
      accepted: false,
      detail: "The Mac has no record of accepting this request.",
    };
    appendEvent({
      type: "ack-status",
      requestId: message.requestId,
      accepted: acknowledgement.accepted,
    });
    send(acknowledgement);
    return;
  }
  if (message.type === "error") {
    appendEvent({ type: "agent-error", message: message.message });
    process.stderr.write(`Remote agent error: ${message.message}\n`);
  }
}

async function waitForLocalAgent() {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    if (existsSync(socketPath) && existsSync(secretPath)) return;
    await new Promise((resolveWait) => setTimeout(resolveWait, 50));
  }
  throw new Error("The native remote agent did not create its local socket");
}

function cleanup() {
  if (stopped) return;
  stopped = true;
  try {
    send({ type: "disable" });
  } catch {
    // Best-effort session shutdown.
  }
  setTimeout(() => {
    client?.end();
    agent.kill("SIGTERM");
    if (
      stateDirectory.startsWith(join(tmpdir(), "terminaldb-live-agent-"))
    ) {
      rmSync(stateDirectory, { recursive: true, force: true });
    }
    process.exit(0);
  }, remoteDisabled ? 0 : 2_500);
}

agent.stderr.on("data", (value) => {
  process.stderr.write(value);
});
agent.on("exit", (code, signal) => {
  if (!stopped) {
    process.stderr.write(
      `Remote agent exited unexpectedly (${String(code ?? signal)})\n`,
    );
    process.exitCode = 1;
  }
});
process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);
process.stdin.setEncoding("utf8");
process.stdin.on("data", (value) => {
  for (const command of value.split(/\r?\n/u).filter(Boolean)) {
    if (command === "disable") {
      appendEvent({ type: "local-disable" });
      send({ type: "disable" });
    } else if (command === "drop-next-ack") {
      dropNextAcknowledgement = true;
      appendEvent({ type: "drop-next-ack-armed" });
    } else if (command === "create-pairing") {
      appendEvent({ type: "create-pairing-requested" });
      send({ type: "createPairing" });
    } else if (command === "pause-agent") {
      appendEvent({ type: "agent-paused" });
      agent.kill("SIGSTOP");
    } else if (command === "resume-agent") {
      agent.kill("SIGCONT");
      appendEvent({ type: "agent-resumed" });
    } else if (command === "close-app") {
      appendEvent({ type: "local-app-closed" });
      client?.end();
    }
  }
});

await waitForLocalAgent();
client = net.createConnection(socketPath);
client.setEncoding("utf8");
client.on("data", (value) => {
  buffer += value;
  for (;;) {
    const newline = buffer.indexOf("\n");
    if (newline < 0) break;
    const frame = buffer.slice(0, newline);
    buffer = buffer.slice(newline + 1);
    if (frame) handle(JSON.parse(frame));
  }
});
await new Promise((resolveConnect, rejectConnect) => {
  client.once("connect", resolveConnect);
  client.once("error", rejectConnect);
});
const secret = readFileSync(secretPath, "utf8");
send({ type: "hello", secret, instanceId: "instance-live-qa" });
send({ type: "inventory", instance: inventory() });
send({
  type: "enable",
  baseURL,
  enrollmentCode: enrollment.enrollmentCode,
});
process.stdout.write(
  `${JSON.stringify({ event: "starting", stateDirectory })}\n`,
);

await new Promise(() => {});
