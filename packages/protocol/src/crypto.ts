import { deflateSync, inflateSync } from "fflate";

import {
  base64UrlDecode,
  base64UrlEncode,
  randomIdentifier,
  text,
  utf8,
  wireSize,
} from "./encoding.js";
import {
  encryptedEnvelopeSchema,
  MAX_WIRE_BYTES,
  PROTOCOL_VERSION,
  type EncryptedEnvelope,
  type RemotePayload,
  type RemoteRoute,
  type SessionKeys,
} from "./types.js";

const P256 = { name: "ECDH", namedCurve: "P-256" } as const;

function arrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(bytes.byteLength);
  copy.set(bytes);
  return copy.buffer;
}

export async function generateIdentityKeyPair(): Promise<CryptoKeyPair> {
  return crypto.subtle.generateKey(P256, false, ["deriveBits"]);
}

export async function exportPublicKey(key: CryptoKey): Promise<JsonWebKey> {
  return crypto.subtle.exportKey("jwk", key);
}

export async function importPublicKey(key: JsonWebKey): Promise<CryptoKey> {
  return crypto.subtle.importKey("jwk", key, P256, true, []);
}

export async function deriveSessionKeys(input: {
  readonly privateKey: CryptoKey;
  readonly peerPublicKey: JsonWebKey;
  readonly pairingSecret: string;
  readonly sessionId: string;
  readonly role: "mac" | "controller";
}): Promise<SessionKeys> {
  const peer = await importPublicKey(input.peerPublicKey);
  const shared = await crypto.subtle.deriveBits(
    { name: "ECDH", public: peer },
    input.privateKey,
    256,
  );
  const material = await crypto.subtle.importKey(
    "raw",
    shared,
    "HKDF",
    false,
    ["deriveBits"],
  );
  const expanded = await crypto.subtle.deriveBits(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: arrayBuffer(utf8(input.pairingSecret)),
      info: arrayBuffer(utf8(`TerminalDB Remote v1:${input.sessionId}`)),
    },
    material,
    512,
  );
  const bytes = new Uint8Array(expanded);
  const macToController = bytes.slice(0, 32);
  const controllerToMac = bytes.slice(32, 64);
  const sendBytes =
    input.role === "mac" ? macToController : controllerToMac;
  const receiveBytes =
    input.role === "mac" ? controllerToMac : macToController;
  const send = await crypto.subtle.importKey(
    "raw",
    sendBytes,
    "AES-GCM",
    false,
    ["encrypt"],
  );
  const receive = await crypto.subtle.importKey(
    "raw",
    receiveBytes,
    "AES-GCM",
    false,
    ["decrypt"],
  );
  return { send, receive };
}

function compressedPayload(payload: RemotePayload): {
  readonly bytes: Uint8Array;
  readonly compression: "none" | "deflate";
} {
  const plain = utf8(JSON.stringify(payload));
  const compressed = deflateSync(plain, { level: 1 });
  return compressed.byteLength + 8 < plain.byteLength
    ? { bytes: compressed, compression: "deflate" }
    : { bytes: plain, compression: "none" };
}

function additionalData(envelope: Omit<EncryptedEnvelope, "ciphertext" | "nonce">): Uint8Array {
  const ordered = Object.fromEntries(
    Object.entries(envelope).sort(([left], [right]) => left.localeCompare(right)),
  );
  return utf8(JSON.stringify(ordered));
}

export async function encryptEnvelope(input: {
  readonly key: CryptoKey;
  readonly route: RemoteRoute;
  readonly sessionId: string;
  readonly sourceId?: string;
  readonly destinationId?: string;
  readonly generation: number;
  readonly sequence: number;
  readonly payload: RemotePayload;
  readonly ttlMs: number;
  readonly requestId?: string;
  readonly now?: number;
}): Promise<EncryptedEnvelope> {
  const sentAt = input.now ?? Date.now();
  const prepared = compressedPayload(input.payload);
  const metadata = {
    version: PROTOCOL_VERSION,
    route: input.route,
    sessionId: input.sessionId,
    ...(input.sourceId ? { sourceId: input.sourceId } : {}),
    ...(input.destinationId ? { destinationId: input.destinationId } : {}),
    generation: input.generation,
    sequence: input.sequence,
    requestId: input.requestId ?? randomIdentifier(),
    sentAt,
    expiresAt: sentAt + input.ttlMs,
    compression: prepared.compression,
  } as const;
  const nonce = new Uint8Array(12);
  crypto.getRandomValues(nonce);
  const encrypted = await crypto.subtle.encrypt(
    {
      name: "AES-GCM",
      iv: arrayBuffer(nonce),
      additionalData: arrayBuffer(additionalData(metadata)),
      tagLength: 128,
    },
    input.key,
    arrayBuffer(prepared.bytes),
  );
  const envelope: EncryptedEnvelope = {
    ...metadata,
    nonce: base64UrlEncode(nonce),
    ciphertext: base64UrlEncode(new Uint8Array(encrypted)),
  };
  if (wireSize(envelope) > MAX_WIRE_BYTES) {
    throw new RangeError(`Encrypted envelope exceeds ${MAX_WIRE_BYTES} bytes`);
  }
  return envelope;
}

export async function decryptEnvelope(
  key: CryptoKey,
  candidate: unknown,
  now = Date.now(),
): Promise<RemotePayload> {
  const envelope = encryptedEnvelopeSchema.parse(candidate);
  if (envelope.expiresAt < now) throw new Error("Envelope expired");
  const { ciphertext: _ciphertext, nonce: _nonce, ...metadata } = envelope;
  const decrypted = await crypto.subtle.decrypt(
    {
      name: "AES-GCM",
      iv: arrayBuffer(base64UrlDecode(envelope.nonce)),
      additionalData: arrayBuffer(additionalData(metadata)),
      tagLength: 128,
    },
    key,
    arrayBuffer(base64UrlDecode(envelope.ciphertext)),
  );
  const bytes = new Uint8Array(decrypted);
  const plain =
    envelope.compression === "deflate" ? inflateSync(bytes) : bytes;
  return JSON.parse(text(plain)) as RemotePayload;
}
