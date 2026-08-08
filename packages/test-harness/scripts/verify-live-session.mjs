#!/usr/bin/env node

import { spawn } from "node:child_process";
import {
  existsSync,
  readFileSync,
} from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

import {
  base64UrlEncode,
  decryptEnvelope,
  deriveSessionKeys,
  encryptEnvelope,
  exportPublicKey,
  generateIdentityKeyPair,
  PROTOCOL_VERSION,
  utf8,
} from "@terminaldb/protocol";

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
const received = [];
let sequence = Math.floor(Math.random() * 1_000_000_000);
let harness;
let socket;
let ready;

function delay(milliseconds) {
  return new Promise((resolveDelay) => setTimeout(resolveDelay, milliseconds));
}

async function waitFor(description, predicate, timeout = 20_000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await delay(50);
  }
  throw new Error(`Timed out waiting for ${description}`);
}

function readEvents(path) {
  if (!path || !existsSync(path)) return [];
  return readFileSync(path, "utf8")
    .split(/\r?\n/u)
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

function arrayBuffer(bytes) {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

async function sha256(value) {
  const hash = await crypto.subtle.digest(
    "SHA-256",
    arrayBuffer(utf8(value)),
  );
  return base64UrlEncode(new Uint8Array(hash));
}

async function authenticatedHeaders({
  method,
  path,
  body,
  principalId,
  privateKey,
}) {
  const timestamp = Date.now().toString();
  const nonce = crypto.randomUUID();
  const canonical = [
    method.toUpperCase(),
    path,
    timestamp,
    nonce,
    await sha256(body),
  ].join("\n");
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    privateKey,
    arrayBuffer(utf8(canonical)),
  );
  return {
    "content-type": "application/json",
    "x-terminaldb-principal": principalId,
    "x-terminaldb-timestamp": timestamp,
    "x-terminaldb-nonce": nonce,
    "x-terminaldb-signature": base64UrlEncode(new Uint8Array(signature)),
  };
}

async function controllerRequest({
  method = "POST",
  path,
  body = {},
  principalId,
  privateKey,
  expectSuccess = true,
}) {
  const bodyText = JSON.stringify(body);
  const response = await fetch(`${baseURL}${path}`, {
    method,
    headers: await authenticatedHeaders({
      method,
      path,
      body: bodyText,
      principalId,
      privateKey,
    }),
    body: bodyText,
  });
  const result = await response.json().catch(() => ({}));
  if (expectSuccess && !response.ok) {
    throw new Error(
      `${path} returned ${response.status}: ${result.error ?? "unknown error"}`,
    );
  }
  return { response, result };
}

async function pairingRequest(pairingId, body) {
  const response = await fetch(
    `${baseURL}/api/v1/pairings/${encodeURIComponent(pairingId)}/redeem`,
    {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    },
  );
  return {
    response,
    result: await response.json().catch(() => ({})),
  };
}

async function sendEncrypted(route, payload, keys, paired, ttlMs = 10_000) {
  const envelope = await encryptEnvelope({
    key: keys.send,
    route,
    sessionId: paired.sessionId,
    sourceId: paired.controllerId,
    generation: paired.generation,
    sequence: ++sequence,
    payload,
    ttlMs,
  });
  socket.send(JSON.stringify(envelope));
  return envelope;
}

function message(route, predicate = () => true) {
  return received.find(
    (entry) => entry.envelope.route === route && predicate(entry.payload),
  );
}

function commandCount(eventsPath, requestId) {
  return readEvents(eventsPath).filter(
    (event) =>
      event.type === "remote-command" &&
      event.requestId === requestId,
  ).length;
}

async function openSocket(url, receiveKey) {
  return new Promise((resolveOpen, rejectOpen) => {
    const candidate = new WebSocket(url);
    const timeout = setTimeout(() => {
      candidate.close();
      rejectOpen(new Error("Controller WebSocket did not open"));
    }, 15_000);
    candidate.addEventListener("open", () => {
      clearTimeout(timeout);
      resolveOpen(candidate);
    });
    candidate.addEventListener("error", () => {
      clearTimeout(timeout);
      rejectOpen(new Error("Controller WebSocket failed"));
    });
    candidate.addEventListener("message", (event) => {
      void (async () => {
        const envelope = JSON.parse(String(event.data));
        const payload = await decryptEnvelope(receiveKey, envelope);
        received.push({ envelope, payload });
      })().catch((error) => {
        process.stderr.write(`Unable to decrypt relay message: ${error.message}\n`);
      });
    });
  });
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
      "--rotation-seconds",
      "8",
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
      const event = JSON.parse(line);
      if (event.event === "ready") ready = event;
    }
  });
  harness.stderr.on("data", (chunk) => process.stderr.write(chunk));
  await waitFor("native Mac harness pairing", () => ready, 30_000);

  const pairingURL = new URL(readFileSync(ready.pairingFile, "utf8"));
  const pairingId = pairingURL.pathname.split("/").filter(Boolean).at(-1);
  const secret = pairingURL.hash.slice(1);
  if (!pairingId || !secret) throw new Error("Native Mac returned an invalid pairing URL");

  const signing = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign", "verify"],
  );
  const agreement = await generateIdentityKeyPair();
  const publicBody = {
    secret,
    deviceName: "TerminalDB Live QA",
    signingPublicKey: await crypto.subtle.exportKey("jwk", signing.publicKey),
    agreementPublicKey: await exportPublicKey(agreement.publicKey),
  };

  const incompatible = await pairingRequest(pairingId, {
    ...publicBody,
    protocolVersion: 999,
  });
  if (incompatible.response.status !== 409) {
    throw new Error(`Protocol mismatch returned ${incompatible.response.status}, expected 409`);
  }

  const pairedResponse = await pairingRequest(pairingId, {
    ...publicBody,
    protocolVersion: PROTOCOL_VERSION,
  });
  if (!pairedResponse.response.ok) {
    throw new Error(`Pairing failed (${pairedResponse.response.status})`);
  }
  const paired = pairedResponse.result;
  const replay = await pairingRequest(pairingId, {
    ...publicBody,
    protocolVersion: PROTOCOL_VERSION,
  });
  if (replay.response.ok) throw new Error("Single-use pairing link replay succeeded");

  const keys = await deriveSessionKeys({
    privateKey: agreement.privateKey,
    peerPublicKey: paired.macAgreementPublicKey,
    pairingSecret: secret,
    sessionId: paired.sessionId,
    role: "controller",
  });
  const ticket = await controllerRequest({
    path: "/api/v1/tickets",
    body: {
      sessionId: paired.sessionId,
      role: "controller",
      clientId: paired.controllerId,
    },
    principalId: paired.controllerId,
    privateKey: signing.privateKey,
  });
  const socketURL = new URL(ticket.result.websocketUrl, baseURL);
  socketURL.searchParams.set("ticket", ticket.result.ticket);
  socket = await openSocket(socketURL, keys.receive);

  await sendEncrypted(
    "presence",
    { visible: true, tabId: "tab-live-claude" },
    keys,
    paired,
  );
  await sendEncrypted(
    "resync.request",
    { reason: "live-qa", tabId: "tab-live-claude", requests: [] },
    keys,
    paired,
    30_000,
  );
  await sendEncrypted(
    "health.ping",
    { sentAt: Date.now() },
    keys,
    paired,
  );
  await waitFor("inventory", () => message("inventory"));
  await waitFor(
    "terminal viewport",
    () => message("viewport.snapshot", (payload) => payload.tabId === "tab-live-claude"),
  );
  await waitFor("health acknowledgement", () => message("health.pong"));
  await sendEncrypted(
    "pty.resize",
    {
      tabId: "tab-live-claude",
      columns: 132,
      rows: 38,
      active: true,
    },
    keys,
    paired,
    10_000,
  );
  await waitFor(
    "bounded PTY resize",
    () => readEvents(ready.eventsFile).find(
      (event) => event.type === "resize" &&
        event.tabId === "tab-live-claude" &&
        event.columns === 132 &&
        event.rows === 38 &&
        event.active === true,
    ),
  );
  await waitFor(
    "trusted controller inventory",
    () =>
      readEvents(ready.eventsFile).find(
        (event) => event.type === "status" && event.controllerCount === 1,
      ),
  );

  const input = await sendEncrypted(
    "pty.input",
    { tabId: "tab-live-claude", input: "printf live-qa" },
    keys,
    paired,
    5_000,
  );
  await waitFor(
    "terminal command acknowledgement",
    () => message("ack", (payload) => payload.requestId === input.requestId && payload.accepted),
  );
  await waitFor(
    "terminal command output",
    () => message("pty.output", (payload) => String(payload.text).includes("printf live-qa")),
  );

  const account = await sendEncrypted(
    "account.switch",
    { tabId: "tab-live-claude", accountId: "account-secondary" },
    keys,
    paired,
    5_000,
  );
  await waitFor(
    "Claude account switch acknowledgement",
    () => message("ack", (payload) => payload.requestId === account.requestId && payload.accepted),
  );
  await waitFor(
    "switched account inventory",
    () =>
      received.find(
        (entry) =>
          entry.envelope.route === "inventory" &&
          entry.payload.instances
            ?.flatMap((instance) => instance.tabs)
            .some(
              (tab) =>
                tab.id === "tab-live-claude" &&
                tab.accountId === "account-secondary",
            ),
      ),
  );

  const usage = await sendEncrypted(
    "usage.refresh",
    { tabId: "tab-live-claude" },
    keys,
    paired,
    5_000,
  );
  await waitFor(
    "usage refresh acknowledgement",
    () => message("ack", (payload) => payload.requestId === usage.requestId && payload.accepted),
  );

  harness.stdin.write("drop-next-ack\n");
  await waitFor(
    "fault injection arming",
    () =>
      readEvents(ready.eventsFile).find(
        (event) => event.type === "drop-next-ack-armed",
      ),
  );
  const uncertain = await sendEncrypted(
    "pty.input",
    { tabId: "tab-live-claude", input: "printf exactly-once" },
    keys,
    paired,
    5_000,
  );
  await waitFor(
    "intentionally unacknowledged command execution",
    () => commandCount(ready.eventsFile, uncertain.requestId) === 1,
  );
  await sendEncrypted(
    "resync.request",
    {
      reason: "delivery-uncertain",
      tabId: "tab-live-claude",
      requests: [
        {
          requestId: uncertain.requestId,
          route: "pty.input",
          tabId: "tab-live-claude",
        },
      ],
    },
    keys,
    paired,
    30_000,
  );
  await waitFor(
    "delivery uncertainty resolution",
    () => message("ack", (payload) => payload.requestId === uncertain.requestId && payload.accepted),
  );
  if (commandCount(ready.eventsFile, uncertain.requestId) !== 1) {
    throw new Error("The uncertain terminal command executed more than once");
  }

  harness.stdin.write("create-pairing\n");
  await waitFor(
    "replacement pairing link",
    () =>
      readEvents(ready.eventsFile).find(
        (event) => event.type === "pairing-updated" && event.revision === 2,
      ),
  );
  await waitFor(
    "native make-before-break rotation",
    () =>
      readEvents(ready.eventsFile).find(
        (event) => event.type === "status" && event.state === "rotating",
      ),
    20_000,
  );
  const rotationIndex = readEvents(ready.eventsFile).findLastIndex(
    (event) => event.type === "status" && event.state === "rotating",
  );
  await waitFor(
    "native rotation resynchronization",
    () =>
      readEvents(ready.eventsFile)
        .slice(rotationIndex + 1)
        .find(
          (event) =>
            event.type === "status" &&
            (event.state === "live" || event.state === "resynchronizing"),
        ),
  );

  const oldControllerSocket = socket;
  const replacementTicket = await controllerRequest({
    path: "/api/v1/tickets",
    body: {
      sessionId: paired.sessionId,
      role: "controller",
      clientId: paired.controllerId,
    },
    principalId: paired.controllerId,
    privateKey: signing.privateKey,
  });
  const replacementURL = new URL(replacementTicket.result.websocketUrl, baseURL);
  replacementURL.searchParams.set("ticket", replacementTicket.result.ticket);
  socket = await openSocket(replacementURL, keys.receive);
  oldControllerSocket.close(1000, "Controller rotation handover");
  const healthCount = received.filter(
    (entry) => entry.envelope.route === "health.pong",
  ).length;
  await sendEncrypted(
    "health.ping",
    { sentAt: Date.now() },
    keys,
    paired,
  );
  await waitFor(
    "replacement controller connection after old disconnect",
    () =>
      received.filter((entry) => entry.envelope.route === "health.pong")
        .length > healthCount,
  );

  let desktopExitClosedController = false;
  const controllerClosed = new Promise((resolveClose) => {
    socket.addEventListener("close", () => {
      desktopExitClosedController = true;
      resolveClose();
    }, { once: true });
  });
  harness.stdin.write("close-app\n");
  await waitFor(
    "desktop app exit",
    () => readEvents(ready.eventsFile).some((event) => event.type === "local-app-closed"),
  );
  await Promise.race([
    controllerClosed,
    delay(12_000).then(() => {
      throw new Error("Closing the desktop app did not close the controller WebSocket");
    }),
  ]);
  const endedTicket = await controllerRequest({
    path: "/api/v1/tickets",
    body: {
      sessionId: paired.sessionId,
      role: "controller",
      clientId: paired.controllerId,
    },
    principalId: paired.controllerId,
    privateKey: signing.privateKey,
    expectSuccess: false,
  });
  if (endedTicket.response.ok) {
    throw new Error("A controller obtained a ticket after the desktop session ended");
  }

  const events = readEvents(ready.eventsFile);
  const result = {
    success: true,
    encryptedRoutes: [...new Set(received.map((entry) => entry.envelope.route))].sort(),
    terminalCommands: events.filter((event) => event.type === "remote-command").length,
    controllerListed: events.some(
      (event) => event.type === "status" && event.controllerCount === 1,
    ),
    pairingReplayRejected: !replay.response.ok,
    protocolMismatchRejected: incompatible.response.status === 409,
    uncertainDeliveryResolvedExactlyOnce:
      commandCount(ready.eventsFile, uncertain.requestId) === 1,
    replacementPairingCreated: events.some(
      (event) => event.type === "pairing-updated" && event.revision === 2,
    ),
    nativeMakeBeforeBreakRotation: events.some(
      (event) => event.type === "status" && event.state === "rotating",
    ),
    controllerMakeBeforeBreakRotation: true,
    ptyGeometryNegotiated: events.some(
      (event) => event.type === "resize" &&
        event.active === true &&
        event.columns === 132 &&
        event.rows === 38,
    ),
    desktopExitClosedController,
    endedSessionControllerRejected: !endedTicket.response.ok,
  };
  process.stdout.write(`${JSON.stringify(result)}\n`);
}

try {
  await main();
} finally {
  socket?.close(1000, "Live QA complete");
  if (harness && harness.exitCode === null) {
    harness.stdin.write("disable\n");
    await delay(2_500);
    harness.kill("SIGTERM");
  }
}
