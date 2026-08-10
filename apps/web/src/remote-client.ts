import {
  decryptEnvelope,
  deriveSessionKeys,
  encryptEnvelope,
  PROTOCOL_VERSION,
  SIDE_EFFECT_TTL_MS,
  SNAPSHOT_TTL_MS,
  type EncryptedEnvelope,
  type InventoryPayload,
  type PTYOutputPayload,
  type RemotePublicConfiguration,
  type RemoteRoute,
} from "@terminaldb/protocol";

import {
  accountAccessToken,
  type AccountAuthConfiguration,
} from "./account-auth";
import {
  authenticatedHeaders,
  clearControllerSession,
  loadControllerSession,
  loadOrCreateBrowserId,
  loadOrCreateIdentity,
  saveControllerSession,
  type StoredControllerSession,
} from "./identity";
import { SnapshotAssembler } from "./snapshot-assembly";

interface PairingResponse {
  readonly controllerId: string;
  readonly sessionId: string;
  readonly generation: number;
  readonly protocolVersion: number;
  readonly macAgreementPublicKey: JsonWebKey;
}

interface AccountControllerResponse extends PairingResponse {
  readonly keySalt: string;
}

export interface AccountSessionSummary {
  readonly sessionId: string;
  readonly deviceId: string;
  readonly deviceName: string;
  readonly generation: number;
  readonly createdAt: number;
}

export type AccountDeviceState = "online" | "connecting" | "offline";

export interface AccountDeviceSummary {
  readonly deviceId: string;
  readonly deviceName: string;
  readonly registeredAt: number;
  readonly lastSeenAt: number;
  readonly state: AccountDeviceState;
  readonly sessionId?: string;
  readonly sessionCreatedAt?: number;
}

interface TicketResponse {
  readonly ticket: string;
  readonly websocketUrl: string;
}

export const CONNECTION_ROTATION_MS = 110 * 60 * 1_000;
export const ROTATION_HANDOVER_MS = 30_000;
export const IDLE_HEALTH_INTERVAL_MS = 4 * 60 * 1_000;
export const MAC_STALE_AFTER_MS = 45_000;
export const MAC_OFFLINE_AFTER_MS = 60_000;
export const RECONNECT_DELAYS_MS = [
  500,
  1_000,
  2_000,
  4_000,
  8_000,
  15_000,
  30_000,
] as const;

type EndedSessionReason = "remote-ended" | "controller-revoked";

class EndedSessionError extends Error {
  readonly reason: EndedSessionReason;

  constructor(reason: EndedSessionReason, message: string) {
    super(message);
    this.name = "EndedSessionError";
    this.reason = reason;
  }
}

export function endedSessionReason(
  status: number,
  detail = "",
): EndedSessionReason | undefined {
  if (status === 410 || /session\s+(?:has\s+)?ended/iu.test(detail)) {
    return "remote-ended";
  }
  if (status === 401 || /revoked|unknown principal/iu.test(detail)) {
    return "controller-revoked";
  }
  if (status === 403 || status === 404) return "remote-ended";
  return undefined;
}

function randomSequenceBase(): number {
  const value = new Uint32Array(1);
  crypto.getRandomValues(value);
  return (value[0] ?? 0) * 1_000_000;
}

export function fullJitterReconnectDelay(
  attempt: number,
  random = Math.random(),
): number {
  const boundedAttempt = Math.max(0, Math.floor(attempt));
  const base =
    RECONNECT_DELAYS_MS[Math.min(boundedAttempt, RECONNECT_DELAYS_MS.length - 1)] ??
    30_000;
  return Math.max(0, Math.min(1, random)) * base;
}

export function hasSequenceGap(previousHighWater: number, incoming: number): boolean {
  return previousHighWater > 0 && incoming > previousHighWater + 1;
}

export interface RemoteClientEvents {
  readonly onSocketOpen: () => void;
  readonly onSocketClose: (phoneOffline: boolean) => void;
  readonly onSynchronizationStart: () => void;
  readonly onSynchronized: () => void;
  readonly onInventory: (inventory: InventoryPayload) => void;
  readonly onOutput: (output: PTYOutputPayload) => void;
  readonly onHealth: (rttMs: number) => void;
  readonly onMacStale: () => void;
  readonly onMacOffline: () => void;
  readonly onRotating: () => void;
  readonly onSessionEnded: (reason?: string | undefined) => void;
  readonly onAccountBootstrap: (bootstrapToken: string, expiresAt: number) => void;
  readonly onAck: (requestId: string, accepted: boolean, detail?: string | undefined) => void;
  readonly onProtocolError: (error: Error) => void;
}

export async function loadPublicConfiguration(): Promise<RemotePublicConfiguration> {
  try {
    const response = await fetch("/api/config", {
      headers: { accept: "application/json" },
      cache: "no-store",
    });
    if (!response.ok) throw new Error(`Configuration returned ${response.status}`);
    return (await response.json()) as RemotePublicConfiguration;
  } catch (error) {
    if (import.meta.env.DEV) {
      return {
        apiBaseUrl: location.origin,
        websocketUrl: "",
        protocolVersion: PROTOCOL_VERSION,
        region: "local",
        pairingEnabled: true,
        mockMode: true,
      };
    }
    throw error;
  }
}

export function controllerDeviceName(userAgent = navigator.userAgent): string {
  if (userAgent.includes("iPad")) return "iPad";
  if (userAgent.includes("iPhone")) return "iPhone";
  if (userAgent.includes("Android")) return "Android phone";
  return "Web browser";
}

export async function redeemPairing(input: {
  readonly pairingId: string;
  readonly secret: string;
}): Promise<StoredControllerSession> {
  const identity = await loadOrCreateIdentity();
  const response = await fetch(`/api/v1/pairings/${encodeURIComponent(input.pairingId)}/redeem`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      secret: input.secret,
      protocolVersion: PROTOCOL_VERSION,
      signingPublicKey: identity.signingPublicKey,
      agreementPublicKey: identity.agreementPublicKey,
      deviceName: controllerDeviceName(),
    }),
  });
  if (!response.ok) {
    const failure = await response.json().catch(() => ({})) as {
      error?: string;
    };
    if (
      response.status === 409 &&
      failure.error?.includes("Protocol version")
    ) {
      throw new Error("Update required: the Mac and web protocol versions differ.");
    }
    throw new Error(`Pairing failed (${response.status})`);
  }
  const paired = (await response.json()) as PairingResponse;
  if (paired.protocolVersion !== PROTOCOL_VERSION) {
    throw new Error("UPDATE_REQUIRED");
  }
  const keys = await deriveSessionKeys({
    privateKey: identity.agreementPrivateKey,
    peerPublicKey: paired.macAgreementPublicKey,
    pairingSecret: input.secret,
    sessionId: paired.sessionId,
    role: "controller",
  });
  const session: StoredControllerSession = {
    controllerId: paired.controllerId,
    sessionId: paired.sessionId,
    generation: paired.generation,
    sendKey: keys.send,
    receiveKey: keys.receive,
    accessMode: "pairing",
  };
  await saveControllerSession(session);
  history.replaceState({}, "", "/remote");
  return session;
}

function bearerHeaders(accessToken: string): Record<string, string> {
  return {
    accept: "application/json",
    authorization: `Bearer ${accessToken}`,
  };
}

export async function listAccountSessions(
  accessToken: string,
): Promise<readonly AccountSessionSummary[]> {
  const response = await fetch("/api/v1/account/sessions", {
    headers: bearerHeaders(accessToken),
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`Session discovery failed (${response.status})`);
  const body = (await response.json()) as { sessions?: AccountSessionSummary[] };
  return body.sessions ?? [];
}

export async function listAccountDevices(
  accessToken: string,
): Promise<readonly AccountDeviceSummary[]> {
  const response = await fetch("/api/v1/account/devices", {
    headers: bearerHeaders(accessToken),
    cache: "no-store",
  });
  if (!response.ok) throw new Error(`Mac discovery failed (${response.status})`);
  const body = (await response.json()) as { devices?: AccountDeviceSummary[] };
  return body.devices ?? [];
}

export async function createAccountEnrollment(
  accessToken: string,
): Promise<{ readonly enrollmentCode: string; readonly expiresAt: number }> {
  const response = await fetch("/api/v1/account/enrollments", {
    method: "POST",
    headers: {
      ...bearerHeaders(accessToken),
      "content-type": "application/json",
    },
    body: "{}",
  });
  if (!response.ok) throw new Error(`Mac enrollment failed (${response.status})`);
  return (await response.json()) as {
    enrollmentCode: string;
    expiresAt: number;
  };
}

export async function completeAccountBootstrap(input: {
  readonly accessToken: string;
  readonly bootstrapToken: string;
}): Promise<{ readonly completed: true; readonly deviceId: string }> {
  const response = await fetch("/api/v1/account/bootstrap/complete", {
    method: "POST",
    headers: {
      ...bearerHeaders(input.accessToken),
      "content-type": "application/json",
    },
    body: JSON.stringify({ bootstrapToken: input.bootstrapToken }),
  });
  if (!response.ok) {
    const failure = await response.json().catch(() => ({})) as { error?: string };
    throw new Error(failure.error ?? `Mac connection failed (${response.status})`);
  }
  return (await response.json()) as { completed: true; deviceId: string };
}

export async function deleteTerminalDBAccount(accessToken: string): Promise<void> {
  const response = await fetch("/api/v1/account", {
    method: "DELETE",
    headers: bearerHeaders(accessToken),
  });
  if (!response.ok) {
    const failure = await response.json().catch(() => ({})) as { error?: string };
    throw new Error(failure.error ?? `Account deletion failed (${response.status})`);
  }
}

export async function openAccountSession(input: {
  readonly sessionId: string;
  readonly accessToken: string;
}): Promise<StoredControllerSession> {
  const identity = await loadOrCreateIdentity();
  const browserId = await loadOrCreateBrowserId();
  const path = `/api/v1/account/sessions/${encodeURIComponent(input.sessionId)}/controllers`;
  const response = await fetch(path, {
    method: "POST",
    headers: {
      ...bearerHeaders(input.accessToken),
      "content-type": "application/json",
    },
    body: JSON.stringify({
      browserId,
      protocolVersion: PROTOCOL_VERSION,
      signingPublicKey: identity.signingPublicKey,
      agreementPublicKey: identity.agreementPublicKey,
      deviceName: controllerDeviceName(),
    }),
  });
  if (!response.ok) {
    const failure = await response.json().catch(() => ({})) as { error?: string };
    throw new Error(failure.error ?? `Session access failed (${response.status})`);
  }
  const registered = (await response.json()) as AccountControllerResponse;
  const keys = await deriveSessionKeys({
    privateKey: identity.agreementPrivateKey,
    peerPublicKey: registered.macAgreementPublicKey,
    pairingSecret: registered.keySalt,
    sessionId: registered.sessionId,
    role: "controller",
  });
  const session: StoredControllerSession = {
    controllerId: registered.controllerId,
    sessionId: registered.sessionId,
    generation: registered.generation,
    sendKey: keys.send,
    receiveKey: keys.receive,
    accessMode: "account",
  };
  await saveControllerSession(session);
  return session;
}

interface PendingAcknowledgement {
  readonly resolve: (requestId: string) => void;
  readonly reject: (error: Error) => void;
  readonly timer: number;
  readonly route: RemoteRoute;
  readonly tabId?: string | undefined;
}

interface UncertainRequest {
  readonly requestId: string;
  readonly route: RemoteRoute;
  readonly tabId?: string | undefined;
}

export function synchronizationReady(input: {
  readonly inventory: boolean;
  readonly health: boolean;
  readonly viewportRequired: boolean;
  readonly viewport: boolean;
  readonly uncertainRequests: number;
}): boolean {
  return (
    input.inventory &&
    input.health &&
    (!input.viewportRequired || input.viewport) &&
    input.uncertainRequests === 0
  );
}

export class RemoteClient {
  readonly #events: RemoteClientEvents;
  #session: StoredControllerSession | undefined;
  #socket: WebSocket | undefined;
  #opening: Promise<void> | undefined;
  #sequence = randomSequenceBase();
  #highestReceivedSequence = 0;
  readonly #receivedSequences = new Set<number>();
  #rotationTimer: number | undefined;
  #healthTimer: number | undefined;
  #staleTimer: number | undefined;
  #offlineTimer: number | undefined;
  #synchronizationTimer: number | undefined;
  #sequenceGapTimer: number | undefined;
  #reconnectTimer: number | undefined;
  #geometryTimer: number | undefined;
  readonly #pending = new Map<string, PendingAcknowledgement>();
  readonly #uncertain = new Map<string, UncertainRequest>();
  readonly #snapshots = new SnapshotAssembler();
  #attempt = 0;
  #synchronizationAttempt = 0;
  #receivedInventory = false;
  #receivedHealth = false;
  #receivedViewport = false;
  #viewedTabId: string | undefined;
  readonly #viewportGeometry = new Map<string, { columns: number; rows: number }>();
  #lastRttMs = 0;
  #lastMacSeenAt = 0;
  #socketOpenedAt = 0;
  #closed = false;
  #incoming = Promise.resolve();
  #outgoing = Promise.resolve();

  constructor(events: RemoteClientEvents) {
    this.#events = events;
  }

  async connect(): Promise<boolean> {
    this.#closed = false;
    this.#session = await loadControllerSession();
    if (!this.#session) return false;
    await this.#beginOpen();
    return this.#session !== undefined;
  }

  #beginOpen(replacement = false): Promise<void> {
    if (!replacement && this.#opening) return this.#opening;
    const opening = this.#openSocket(replacement).finally(() => {
      if (this.#opening === opening) this.#opening = undefined;
    });
    if (!replacement) this.#opening = opening;
    return opening;
  }

  async #ticket(): Promise<TicketResponse> {
    if (!this.#session) throw new Error("No paired controller session");
    const identity = await loadOrCreateIdentity();
    const accountMode = this.#session.accessMode === "account";
    const path = accountMode ? "/api/v1/account/tickets" : "/api/v1/tickets";
    const body = JSON.stringify({
      sessionId: this.#session.sessionId,
      role: "controller",
      clientId: this.#session.controllerId,
    });
    const signedHeaders = await authenticatedHeaders({
      method: "POST",
      path,
      body,
      principalId: this.#session.controllerId,
      privateKey: identity.signingPrivateKey,
    });
    if (accountMode) {
      const configuration = await loadPublicConfiguration();
      const accountConfiguration = configuration.accountAuth as
        | AccountAuthConfiguration
        | undefined;
      const accessToken = accountConfiguration
        ? await accountAccessToken(accountConfiguration)
        : undefined;
      if (!accessToken) throw new Error("Account sign-in has expired");
      signedHeaders.authorization = `Bearer ${accessToken}`;
    }
    const response = await fetch(path, {
      method: "POST",
      headers: signedHeaders,
      body,
    });
    if (!response.ok) {
      const failure = await response.json().catch(() => ({})) as { error?: string };
      const detail = failure.error ?? `Connection ticket failed (${response.status})`;
      const reason = endedSessionReason(response.status, detail);
      if (reason) throw new EndedSessionError(reason, detail);
      throw new Error(detail);
    }
    return (await response.json()) as TicketResponse;
  }

  async #openSocket(replacement = false): Promise<void> {
    try {
      const ticket = await this.#ticket();
      const socketUrl = new URL(ticket.websocketUrl);
      socketUrl.searchParams.set("ticket", ticket.ticket);
      const socket = new WebSocket(socketUrl);
      await new Promise<void>((resolve, reject) => {
        let opened = false;
        const openTimeout = window.setTimeout(() => {
          if (!opened) socket.close(4000, "Open timeout");
        }, 15_000);
        socket.addEventListener("open", () => {
          opened = true;
          window.clearTimeout(openTimeout);
          if (this.#closed) {
            socket.close(1000, "Controller closed");
            reject(new Error("Remote controller closed"));
            return;
          }
          this.#clearConnectionTimers();
          this.#socket = socket;
          this.#socketOpenedAt = Date.now();
          this.#attempt = 0;
          this.#events.onSocketOpen();
          this.#scheduleMacPresenceDeadlines();
          this.#scheduleHealth();
          this.#rotationTimer = window.setTimeout(() => {
            void this.rotate();
          }, CONNECTION_ROTATION_MS);
          this.#startSynchronization(replacement ? "rotated" : "connected");
          resolve();
        });
        socket.addEventListener("message", (event) => {
          const wire = String(event.data);
          this.#incoming = this.#incoming
            .then(() => this.#handleMessage(wire))
            .catch((error: unknown) => {
              this.#events.onProtocolError(
                error instanceof Error ? error : new Error("Invalid relay message"),
              );
            });
        });
        socket.addEventListener("close", () => {
          window.clearTimeout(openTimeout);
          if (!opened) {
            reject(new Error("WebSocket closed before authentication completed"));
            return;
          }
          if (this.#closed || socket !== this.#socket) return;
          this.#clearConnectionTimers();
          this.#events.onSocketClose(navigator.onLine === false);
          this.#scheduleReconnect();
        });
        socket.addEventListener("error", () => socket.close());
      });
    } catch (error) {
      if (error instanceof EndedSessionError) {
        this.#closed = true;
        this.#clearTimers();
        const existingSocket = this.#socket;
        this.#socket = undefined;
        existingSocket?.close(1000, "Remote session ended");
        this.#session = undefined;
        await clearControllerSession();
        this.#events.onSessionEnded(error.reason);
        return;
      }
      this.#events.onProtocolError(
        error instanceof Error ? error : new Error("Unable to connect"),
      );
      if (!replacement) this.#scheduleReconnect();
      throw error;
    }
  }

  async #handleMessage(wire: string): Promise<void> {
    if (!this.#session) return;
    try {
      const envelope = JSON.parse(wire) as EncryptedEnvelope;
      if (envelope.generation !== this.#session.generation) return;
      if (this.#receivedSequences.has(envelope.sequence)) return;
      this.#receivedSequences.add(envelope.sequence);
      if (this.#highestReceivedSequence === 0) {
        // A controller may pair after the Mac has already emitted messages.
        // Treat its first observed sequence as the local baseline.
        this.#highestReceivedSequence = envelope.sequence;
      } else if (envelope.sequence === this.#highestReceivedSequence + 1) {
        this.#highestReceivedSequence = envelope.sequence;
        while (this.#receivedSequences.has(this.#highestReceivedSequence + 1)) {
          this.#highestReceivedSequence += 1;
        }
      }
      const sequenceGap = [...this.#receivedSequences].some(
        (sequence) => sequence > this.#highestReceivedSequence + 1,
      );
      if (sequenceGap && this.#sequenceGapTimer === undefined) {
        // API Gateway/Lambda delivery can briefly reorder otherwise valid
        // frames. Give the missing frame a small window to arrive before
        // requesting a viewport replacement.
        this.#sequenceGapTimer = window.setTimeout(() => {
          this.#sequenceGapTimer = undefined;
          this.#highestReceivedSequence = Math.max(
            this.#highestReceivedSequence,
            ...this.#receivedSequences,
          );
          this.#startSynchronization("sequence-gap");
        }, 250);
      } else if (!sequenceGap && this.#sequenceGapTimer !== undefined) {
        window.clearTimeout(this.#sequenceGapTimer);
        this.#sequenceGapTimer = undefined;
      }
      if (this.#receivedSequences.size > 1_024) {
        const highestObserved = Math.max(...this.#receivedSequences);
        const floor = Math.max(0, highestObserved - 512);
        for (const sequence of this.#receivedSequences) {
          if (sequence < floor) this.#receivedSequences.delete(sequence);
        }
      }
      const payload = await decryptEnvelope(this.#session.receiveKey, envelope);
      this.#markMacSeen();
      if (envelope.route === "inventory") {
        const inventory = payload as InventoryPayload;
        this.#receivedInventory = true;
        if (!this.#viewedTabId) {
          this.#viewedTabId =
            inventory.selectedTabId ??
            inventory.instances.flatMap((instance) => instance.tabs)[0]?.id;
          if (this.#viewedTabId) {
            this.#receivedViewport = false;
            this.#requestViewport("inventory-selected");
          }
        }
        this.#events.onInventory(inventory);
        this.#finishSynchronizationIfReady();
      } else if (envelope.route === "pty.output" || envelope.route === "viewport.snapshot") {
        const candidate = payload as Partial<PTYOutputPayload>;
        const outputText = envelope.route === "viewport.snapshot"
          ? this.#snapshots.accept(candidate)
          : candidate.text ?? "";
        if (outputText === undefined) return;
        const output: PTYOutputPayload = {
          tabId: candidate.tabId ?? "",
          text: outputText,
          rows: Math.max(1, candidate.rows ?? 24),
          columns: Math.max(1, candidate.columns ?? 80),
          viewport:
            envelope.route === "viewport.snapshot" || candidate.viewport === true,
          ...(candidate.inputMode === "echo" ||
          candidate.inputMode === "application" ||
          candidate.inputMode === "secure"
            ? { inputMode: candidate.inputMode }
            : {}),
          ...(typeof candidate.inputStreamId === "string"
            ? { inputStreamId: candidate.inputStreamId }
            : {}),
          ...(Number.isSafeInteger(candidate.inputThrough) &&
          Number(candidate.inputThrough) > 0
            ? { inputThrough: Number(candidate.inputThrough) }
            : {}),
        };
        this.#events.onOutput(output);
        if (
          envelope.route === "viewport.snapshot" &&
          output.tabId === this.#viewedTabId
        ) {
          const geometry = this.#viewportGeometry.get(output.tabId);
          this.#receivedViewport =
            output.inputMode !== "application" ||
            geometry === undefined ||
            (geometry.columns === output.columns && geometry.rows === output.rows);
          if (!this.#receivedViewport) this.#scheduleViewportResize(output.tabId);
          this.#finishSynchronizationIfReady();
        }
      } else if (envelope.route === "health.pong") {
        const health = payload as { sentAt: number; proactive?: boolean };
        this.#receivedHealth = true;
        this.#finishSynchronizationIfReady();
        if (health.proactive !== true) {
          this.#lastRttMs = Math.max(0, Date.now() - health.sentAt);
        }
        this.#events.onHealth(this.#lastRttMs);
      } else if (envelope.route === "session.ended") {
        const ended = payload as { reason?: string };
        this.#events.onSessionEnded(ended.reason);
        this.close();
      } else if (envelope.route === "account.bootstrap.ready") {
        const bootstrap = payload as { bootstrapToken?: string; expiresAt?: number };
        if (bootstrap.bootstrapToken && Number.isSafeInteger(bootstrap.expiresAt)) {
          this.#events.onAccountBootstrap(
            bootstrap.bootstrapToken,
            Number(bootstrap.expiresAt),
          );
        }
      } else if (envelope.route === "ack") {
        const ack = payload as { requestId: string; accepted: boolean; detail?: string };
        this.#events.onAck(ack.requestId, ack.accepted, ack.detail);
        this.#uncertain.delete(ack.requestId);
        const pending = this.#pending.get(ack.requestId);
        if (pending) {
          window.clearTimeout(pending.timer);
          this.#pending.delete(ack.requestId);
          if (ack.accepted) {
            pending.resolve(ack.requestId);
          } else {
            pending.reject(new Error(ack.detail ?? "The Mac rejected this request"));
          }
        }
        this.#finishSynchronizationIfReady();
      }
    } catch (error) {
      this.#events.onProtocolError(
        error instanceof Error ? error : new Error("Invalid relay message"),
      );
    }
  }

  async send(
    route: RemoteRoute,
    payload: Record<string, unknown>,
    ttlMs = SIDE_EFFECT_TTL_MS,
    waitForAcknowledgement =
      route === "pty.input" ||
      route === "tab.create" ||
      route === "tab.select" ||
      route === "tab.close" ||
      route === "account.switch" ||
      route === "usage.refresh" ||
      route === "account.bootstrap" ||
      route === "session.end",
  ): Promise<string> {
    const sendOperation = this.#outgoing.then(async () => {
      const session = this.#session;
      const socket = this.#socket;
      if (!session || socket?.readyState !== WebSocket.OPEN) {
        throw new Error("Remote session is not live");
      }
      const envelope = await encryptEnvelope({
        key: session.sendKey,
        route,
        sessionId: session.sessionId,
        sourceId: session.controllerId,
        generation: session.generation,
        sequence: ++this.#sequence,
        payload,
        ttlMs,
      });
      if (socket.readyState !== WebSocket.OPEN) {
        throw new Error("Remote session closed before input was sent");
      }
      socket.send(JSON.stringify(envelope));
      return envelope;
    });
    this.#outgoing = sendOperation.then(
      () => undefined,
      () => undefined,
    );
    const envelope = await sendOperation;
    if (!waitForAcknowledgement) return envelope.requestId;
    return new Promise<string>((resolve, reject) => {
      const timer = window.setTimeout(() => {
        this.#pending.delete(envelope.requestId);
        this.#uncertain.set(envelope.requestId, {
          requestId: envelope.requestId,
          route,
          tabId:
            typeof payload.tabId === "string" ? payload.tabId : undefined,
        });
        this.#startSynchronization("delivery-uncertain");
        reject(
          new Error(
            `Delivery uncertain for ${envelope.requestId}. The Mac will be queried before a deliberate resend.`,
          ),
        );
      }, Math.max(1_000, ttlMs + 1_000));
      this.#pending.set(envelope.requestId, {
        resolve,
        reject,
        timer,
        route,
        tabId:
          typeof payload.tabId === "string" ? payload.tabId : undefined,
      });
    });
  }

  async revokeThisController(): Promise<void> {
    if (!this.#session) throw new Error("No paired controller session");
    const identity = await loadOrCreateIdentity();
    const path = `/api/v1/controllers/${encodeURIComponent(this.#session.controllerId)}/revoke`;
    const body = "{}";
    const response = await fetch(path, {
      method: "POST",
      headers: await authenticatedHeaders({
        method: "POST",
        path,
        body,
        principalId: this.#session.controllerId,
        privateKey: identity.signingPrivateKey,
      }),
      body,
    });
    if (!response.ok) throw new Error(`Controller revocation failed (${response.status})`);
  }

  async rotate(): Promise<void> {
    if (this.#closed) return;
    const previous = this.#socket;
    this.#events.onRotating();
    try {
      await this.#beginOpen(true);
      window.setTimeout(() => {
        if (previous && previous !== this.#socket) previous.close(1000, "Connection rotated");
      }, ROTATION_HANDOVER_MS);
    } catch {
      if (previous?.readyState === WebSocket.OPEN) {
        this.#socket = previous;
        this.#events.onSocketOpen();
        this.#scheduleHealth();
        void this.send("resync.request", { reason: "rotation-failed" }, SNAPSHOT_TTL_MS, false);
      } else {
        this.#events.onSocketClose(navigator.onLine === false);
        this.#scheduleReconnect();
      }
    }
  }

  close(): void {
    this.#closed = true;
    this.#clearTimers();
    for (const pending of this.#pending.values()) {
      window.clearTimeout(pending.timer);
      pending.reject(new Error("Remote session closed before the Mac acknowledged the request"));
    }
    this.#pending.clear();
    this.#uncertain.clear();
    this.#snapshots.clear();
    this.#socket?.close(1000, "Controller closed");
  }

  retryNow(): void {
    if (this.#closed) return;
    if (this.#socket?.readyState === WebSocket.OPEN) {
      this.#startSynchronization("manual-retry");
      return;
    }
    if (this.#reconnectTimer) {
      window.clearTimeout(this.#reconnectTimer);
      this.#reconnectTimer = undefined;
    }
    void this.#beginOpen().catch(() => undefined);
  }

  requestViewport(reason = "controller-request"): void {
    this.#requestViewport(reason);
  }

  setViewportGeometry(tabId: string, columns: number, rows: number): void {
    const geometry = {
      columns: Math.max(20, Math.min(500, Math.floor(columns))),
      rows: Math.max(5, Math.min(200, Math.floor(rows))),
    };
    const previous = this.#viewportGeometry.get(tabId);
    if (previous?.columns === geometry.columns && previous.rows === geometry.rows) return;
    this.#viewportGeometry.set(tabId, geometry);
    if (
      tabId !== this.#viewedTabId ||
      document.visibilityState !== "visible" ||
      this.#socket?.readyState !== WebSocket.OPEN
    ) return;
    this.#scheduleViewportResize(tabId);
  }

  setViewing(tabId: string | undefined): void {
    const previousTabId = this.#viewedTabId;
    const changed = previousTabId !== tabId;
    if (
      previousTabId &&
      previousTabId !== tabId &&
      this.#socket?.readyState === WebSocket.OPEN
    ) {
      void this.send(
        "pty.resize",
        { tabId: previousTabId, columns: 0, rows: 0, active: false },
        10_000,
        false,
      ).catch(() => undefined);
    }
    this.#viewedTabId = tabId;
    if (this.#socket?.readyState !== WebSocket.OPEN) return;
    const visible = document.visibilityState === "visible";
    const geometry = tabId ? this.#viewportGeometry.get(tabId) : undefined;
    void this.send(
      "presence",
      { tabId, visible, ...geometry },
      30_000,
      false,
    ).catch(() => undefined);
    if (visible && tabId && geometry) this.#scheduleViewportResize(tabId);
    const synchronized = synchronizationReady({
      inventory: this.#receivedInventory,
      health: this.#receivedHealth,
      viewportRequired: Boolean(this.#viewedTabId),
      viewport: this.#receivedViewport,
      uncertainRequests: this.#uncertain.size,
    });
    if (visible) {
      this.#scheduleMacPresenceDeadlines();
      if (
        this.#synchronizationTimer === undefined &&
        (changed || !synchronized)
      ) {
        // A tab change must use the repeating synchronization loop. A single
        // at-most-once viewport request can be lost on a poor mobile
        // connection and would otherwise leave the new tab without a screen.
        this.#startSynchronization("view-changed");
      }
    } else {
      if (this.#staleTimer) window.clearTimeout(this.#staleTimer);
      this.#staleTimer = undefined;
      if (this.#offlineTimer) window.clearTimeout(this.#offlineTimer);
      this.#offlineTimer = undefined;
    }
  }

  #scheduleHealth(): void {
    if (this.#healthTimer) window.clearInterval(this.#healthTimer);
    this.#healthTimer = window.setInterval(() => {
      void this.send("health.ping", { sentAt: Date.now() }, 20_000, false).catch(() => undefined);
    }, IDLE_HEALTH_INTERVAL_MS);
  }

  #startSynchronization(reason: string): void {
    if (this.#synchronizationTimer) {
      window.clearTimeout(this.#synchronizationTimer);
    }
    this.#receivedInventory = false;
    this.#receivedHealth = false;
    this.#receivedViewport = false;
    this.#synchronizationAttempt = 0;
    this.#events.onSynchronizationStart();
    this.#scheduleMacPresenceDeadlines();
    const request = () => {
      if (
        this.#closed ||
        this.#socket?.readyState !== WebSocket.OPEN ||
        synchronizationReady({
          inventory: this.#receivedInventory,
          health: this.#receivedHealth,
          viewportRequired: Boolean(this.#viewedTabId),
          viewport: this.#receivedViewport,
          uncertainRequests: this.#uncertain.size,
        })
      ) {
        return;
      }
      void this.send(
        "resync.request",
        {
          reason,
          attempt: this.#synchronizationAttempt,
          tabId: this.#viewedTabId,
          ...(this.#viewedTabId
            ? this.#viewportGeometry.get(this.#viewedTabId)
            : undefined),
          requests: [...this.#uncertain.values()],
        },
        SNAPSHOT_TTL_MS,
        false,
      ).catch(() => undefined);
      void this.send(
        "health.ping",
        { sentAt: Date.now() },
        20_000,
        false,
      ).catch(() => undefined);
      const delays = [1_000, 2_000, 4_000, 8_000, 15_000, 30_000];
      const delay = delays[Math.min(this.#synchronizationAttempt, delays.length - 1)] ?? 30_000;
      this.#synchronizationAttempt += 1;
      this.#synchronizationTimer = window.setTimeout(request, delay);
    };
    request();
  }

  #finishSynchronizationIfReady(): void {
    if (
      !synchronizationReady({
        inventory: this.#receivedInventory,
        health: this.#receivedHealth,
        viewportRequired: Boolean(this.#viewedTabId),
        viewport: this.#receivedViewport,
        uncertainRequests: this.#uncertain.size,
      })
    ) {
      return;
    }
    if (this.#synchronizationTimer) {
      window.clearTimeout(this.#synchronizationTimer);
      this.#synchronizationTimer = undefined;
    }
    this.#events.onSynchronized();
  }

  #requestViewport(reason: string): void {
    if (this.#socket?.readyState !== WebSocket.OPEN) return;
    void this.send(
      "resync.request",
      {
        tabId: this.#viewedTabId,
        reason,
        ...(this.#viewedTabId
          ? this.#viewportGeometry.get(this.#viewedTabId)
          : undefined),
        requests: [...this.#uncertain.values()],
      },
      SNAPSHOT_TTL_MS,
      false,
    ).catch(() => undefined);
  }

  #markMacSeen(): void {
    this.#lastMacSeenAt = Date.now();
    this.#scheduleMacPresenceDeadlines();
  }

  #scheduleMacPresenceDeadlines(): void {
    if (this.#staleTimer) window.clearTimeout(this.#staleTimer);
    if (this.#offlineTimer) window.clearTimeout(this.#offlineTimer);
    if (document.visibilityState !== "visible") return;
    const baseline = Math.max(this.#lastMacSeenAt, this.#socketOpenedAt);
    const elapsed = baseline > 0 ? Math.max(0, Date.now() - baseline) : 0;
    if (elapsed >= MAC_OFFLINE_AFTER_MS) {
      this.#staleTimer = undefined;
      this.#offlineTimer = undefined;
      this.#events.onMacOffline();
      return;
    }
    if (elapsed >= MAC_STALE_AFTER_MS) {
      this.#events.onMacStale();
    } else {
      this.#staleTimer = window.setTimeout(() => {
        this.#staleTimer = undefined;
        this.#events.onMacStale();
        this.#startSynchronization("mac-stale");
      }, MAC_STALE_AFTER_MS - elapsed);
    }
    this.#offlineTimer = window.setTimeout(() => {
      this.#offlineTimer = undefined;
      this.#events.onMacOffline();
    }, MAC_OFFLINE_AFTER_MS - elapsed);
  }

  #scheduleViewportResize(tabId: string): void {
    if (this.#geometryTimer) window.clearTimeout(this.#geometryTimer);
    this.#geometryTimer = window.setTimeout(() => {
      this.#geometryTimer = undefined;
      const geometry = this.#viewportGeometry.get(tabId);
      if (
        !geometry ||
        this.#viewedTabId !== tabId ||
        document.visibilityState !== "visible" ||
        this.#socket?.readyState !== WebSocket.OPEN
      ) return;
      void this.send(
        "pty.resize",
        { tabId, ...geometry, active: true },
        10_000,
        false,
      ).catch(() => undefined);
    }, 80);
  }

  #scheduleReconnect(): void {
    if (this.#closed || this.#reconnectTimer) return;
    const delay = fullJitterReconnectDelay(this.#attempt);
    this.#attempt += 1;
    this.#reconnectTimer = window.setTimeout(() => {
      this.#reconnectTimer = undefined;
      void this.#beginOpen().catch(() => undefined);
    }, delay);
  }

  #clearConnectionTimers(): void {
    if (this.#rotationTimer) window.clearTimeout(this.#rotationTimer);
    if (this.#healthTimer) window.clearInterval(this.#healthTimer);
    if (this.#staleTimer) window.clearTimeout(this.#staleTimer);
    if (this.#offlineTimer) window.clearTimeout(this.#offlineTimer);
    if (this.#synchronizationTimer) window.clearTimeout(this.#synchronizationTimer);
    if (this.#sequenceGapTimer) window.clearTimeout(this.#sequenceGapTimer);
    if (this.#geometryTimer) window.clearTimeout(this.#geometryTimer);
    this.#rotationTimer = undefined;
    this.#healthTimer = undefined;
    this.#staleTimer = undefined;
    this.#offlineTimer = undefined;
    this.#synchronizationTimer = undefined;
    this.#sequenceGapTimer = undefined;
    this.#geometryTimer = undefined;
  }

  #clearTimers(): void {
    this.#clearConnectionTimers();
    if (this.#reconnectTimer) window.clearTimeout(this.#reconnectTimer);
    this.#reconnectTimer = undefined;
  }
}
