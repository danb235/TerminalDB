#!/usr/bin/env node

import { execFileSync } from "node:child_process";
import {
  createHash,
  generateKeyPairSync,
  randomUUID,
  sign,
} from "node:crypto";
import {
  mkdtempSync,
  readFileSync,
  rmSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1]
    ? process.argv[index + 1]
    : fallback;
}

const profile = argument("profile", "stelao");
const region = argument("region", "us-west-2");
const stage = argument("stage", "dev");
const apiId = argument("api-id", "utk77niphk");
const baseURL = argument("base-url", "https://dwi1gx38gzrsl.cloudfront.net");
const functionName = argument("function-name", "terminaldb-remote-dev-control");
const temporaryDirectory = mkdtempSync(join(tmpdir(), "terminaldb-socket-probe-"));
const responsePath = join(temporaryDirectory, "enrollment.json");
const { privateKey, publicKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
});
const publicJWK = publicKey.export({ format: "jwk" });
let deviceId;
let sessionId;

function aws(...args) {
  return execFileSync(
    "aws",
    [...args, "--profile", profile, "--region", region],
    { encoding: "utf8", stdio: ["ignore", "pipe", "inherit"] },
  ).trim();
}

function sha256(value) {
  return createHash("sha256").update(value, "utf8").digest("base64url");
}

async function control(path, body, authenticated = true) {
  const method = "POST";
  const bodyText = JSON.stringify(body);
  const headers = {
    accept: "application/json",
    "content-type": "application/json",
  };
  if (authenticated) {
    const timestamp = Date.now().toString();
    const nonce = randomUUID();
    const canonical = [
      method,
      path,
      timestamp,
      nonce,
      sha256(bodyText),
    ].join("\n");
    Object.assign(headers, {
      "x-terminaldb-principal": deviceId,
      "x-terminaldb-timestamp": timestamp,
      "x-terminaldb-nonce": nonce,
      "x-terminaldb-signature": sign(
        "sha256",
        Buffer.from(canonical, "utf8"),
        privateKey,
      ).toString("base64url"),
    });
  }
  const response = await fetch(`${baseURL}${path}`, {
    method,
    headers,
    body: bodyText,
  });
  const result = await response.json();
  if (!response.ok) {
    throw new Error(`${path} returned ${response.status}: ${result.error ?? "unknown error"}`);
  }
  return result;
}

async function createTicket() {
  return control("/api/v1/tickets", {
    sessionId,
    role: "mac",
    clientId: deviceId,
  });
}

async function probe(url) {
  return new Promise((resolveProbe) => {
    const socket = new WebSocket(url);
    let opened = false;
    let settled = false;
    const finish = (result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timeout);
      resolveProbe(result);
    };
    const timeout = setTimeout(() => {
      socket.close();
      finish({ opened: false, detail: "timeout" });
    }, 15_000);
    socket.addEventListener("open", () => {
      opened = true;
      socket.close(1000, "probe complete");
    });
    socket.addEventListener("close", (event) => {
      finish(
        opened
          ? { opened: true }
          : {
              opened: false,
              detail: `close ${event.code}${event.reason ? `: ${event.reason}` : ""}`,
            },
      );
    });
    socket.addEventListener("error", () => {
      finish({ opened: false, detail: "websocket error" });
    });
  });
}

try {
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
  const registered = await control(
    "/api/v1/enrollments/redeem",
    {
      code: enrollment.enrollmentCode,
      deviceName: "TerminalDB WebSocket Probe",
      temporary: true,
      signingPublicKey: publicJWK,
      agreementPublicKey: publicJWK,
    },
    false,
  );
  deviceId = registered.deviceId;
  const session = await control("/api/v1/sessions", { protocolVersion: 1 });
  sessionId = session.sessionId;

  const directTicket = await createTicket();
  const directURL =
    `wss://${apiId}.execute-api.${region}.amazonaws.com/${stage}` +
    `?ticket=${encodeURIComponent(directTicket.ticket)}`;
  const direct = await probe(directURL);
  const directReplay = await probe(directURL);

  const cloudFrontTicket = await createTicket();
  const cloudFrontURL = new URL(cloudFrontTicket.websocketUrl);
  cloudFrontURL.searchParams.set("ticket", cloudFrontTicket.ticket);
  const cloudFront = await probe(cloudFrontURL);

  process.stdout.write(
    `${JSON.stringify({
      direct,
      directReplay,
      cloudFront,
      success: direct.opened && !directReplay.opened && cloudFront.opened,
    })}\n`,
  );
  if (!direct.opened || directReplay.opened || !cloudFront.opened) process.exitCode = 1;
} finally {
  if (deviceId && sessionId) {
    await control(`/api/v1/sessions/${encodeURIComponent(sessionId)}/end`, {})
      .catch(() => undefined);
  }
  if (
    temporaryDirectory.startsWith(join(tmpdir(), "terminaldb-socket-probe-"))
  ) {
    rmSync(temporaryDirectory, { recursive: true, force: true });
  }
}
