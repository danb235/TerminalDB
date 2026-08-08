import { z } from "zod";

export const PROTOCOL_VERSION = 1 as const;
export const MAX_WIRE_BYTES = 30_000;
export const SIDE_EFFECT_TTL_MS = 5_000;
export const SNAPSHOT_TTL_MS = 30_000;

export const connectionStateSchema = z.enum([
  "connecting",
  "live",
  "slow",
  "reconnecting",
  "rotating",
  "phone-offline",
  "mac-offline",
  "resyncing",
  "delivery-uncertain",
  "remote-ended",
  "revoked",
  "update-required",
]);

export type ConnectionState = z.infer<typeof connectionStateSchema>;

export const routeSchema = z.enum([
  "inventory",
  "viewport.snapshot",
  "pty.output",
  "pty.input",
  "pty.resize",
  "tab.create",
  "tab.select",
  "tab.close",
  "claude.state",
  "account.inventory",
  "account.switch",
  "usage.refresh",
  "session.end",
  "session.ended",
  "usage.snapshot",
  "ack",
  "error",
  "presence",
  "resync.request",
  "health.ping",
  "health.pong",
]);

export type RemoteRoute = z.infer<typeof routeSchema>;

export type RemoteInputMode = "echo" | "application" | "secure";

export const encryptedEnvelopeSchema = z.object({
  version: z.literal(PROTOCOL_VERSION),
  route: routeSchema,
  sessionId: z.string().min(16).max(128),
  sourceId: z.string().min(1).max(128).optional(),
  destinationId: z.string().min(1).max(128).optional(),
  generation: z.number().int().nonnegative(),
  sequence: z.number().int().nonnegative(),
  requestId: z.string().min(16).max(128),
  sentAt: z.number().int().positive(),
  expiresAt: z.number().int().positive(),
  compression: z.enum(["none", "deflate"]),
  nonce: z.string().min(16).max(32),
  ciphertext: z.string().min(1),
});

export type EncryptedEnvelope = z.infer<typeof encryptedEnvelopeSchema>;

export interface ClaudeUsageWindow {
  readonly label: "5h" | "7d" | "Fable";
  readonly utilization: number;
  readonly resetsAt?: string;
}

export interface ClaudeAccount {
  readonly id: string;
  readonly label: string;
  readonly email?: string;
  readonly plan?: string;
  readonly signedIn: boolean;
  readonly usage: readonly ClaudeUsageWindow[];
}

export interface RemoteTab {
  readonly id: string;
  readonly instanceId: string;
  readonly windowId: string;
  readonly paneId?: string;
  readonly parentPaneId?: string;
  readonly splitDirection?: "right" | "down";
  readonly title: string;
  readonly directory: string;
  readonly environment: string;
  readonly accountId?: string;
  readonly accountLabel?: string;
  readonly foregroundProcess?: string;
  readonly model?: string;
  readonly inputMode?: RemoteInputMode;
  readonly busy: boolean;
  readonly claudeState?: "ready" | "working" | "attention" | "rate-limit" | "error";
  readonly updatedAt: string;
}

export interface RemoteInstance {
  readonly id: string;
  readonly name: string;
  readonly host: string;
  readonly tabs: readonly RemoteTab[];
}

export interface InventoryPayload {
  readonly instances: readonly RemoteInstance[];
  readonly accounts: readonly ClaudeAccount[];
  readonly selectedTabId?: string;
  readonly capabilities?: readonly string[];
}

export interface PTYOutputPayload {
  readonly tabId: string;
  readonly text: string;
  readonly rows: number;
  readonly columns: number;
  readonly viewport: boolean;
  readonly inputMode?: RemoteInputMode;
  /** Identifies the browser input stream reflected by this output frame. */
  readonly inputStreamId?: string;
  /** Highest contiguous input sequence accepted before this frame was read. */
  readonly inputThrough?: number;
  readonly snapshotId?: string;
  readonly chunkIndex?: number;
  readonly chunkCount?: number;
}

export interface PTYInputPayload {
  readonly tabId: string;
  readonly input: string;
  readonly inputStreamId?: string;
  readonly inputSequence?: number;
}

export interface PTYResizePayload {
  readonly tabId: string;
  readonly columns: number;
  readonly rows: number;
  readonly active: boolean;
}

export interface TabCommandPayload {
  readonly tabId: string;
}

export interface AccountSwitchPayload {
  readonly tabId: string;
  readonly accountId: string;
}

export interface AckPayload {
  readonly requestId: string;
  readonly accepted: boolean;
  readonly code?: string;
  readonly detail?: string;
  readonly inputStreamId?: string;
  readonly inputThrough?: number;
}

export type RemotePayload =
  | InventoryPayload
  | PTYOutputPayload
  | PTYInputPayload
  | TabCommandPayload
  | AccountSwitchPayload
  | AckPayload
  | Record<string, unknown>;

export interface SessionKeys {
  readonly send: CryptoKey;
  readonly receive: CryptoKey;
}

export interface RemotePublicConfiguration {
  readonly apiBaseUrl: string;
  readonly websocketUrl: string;
  readonly protocolVersion: number;
  readonly region: string;
  readonly pairingEnabled: boolean;
  readonly accountAuth?: {
    readonly clientId: string;
    readonly domain: string;
    readonly issuer: string;
    readonly callbackPath: string;
  };
  readonly mockMode?: boolean;
}
