import { describe, expect, it } from "vitest";
import { inflateSync } from "fflate";

import {
  base64UrlDecode,
  decryptEnvelope,
  deriveSessionKeys,
  encryptEnvelope,
  estimateWebSocketCost,
  exportPublicKey,
  generateIdentityKeyPair,
  MAX_WIRE_BYTES,
  routeSchema,
  wireSize,
} from "./index.js";

describe("TerminalDB remote protocol", () => {
  it("recognizes the acknowledged native tab-management routes", () => {
    expect(routeSchema.parse("pty.resize")).toBe("pty.resize");
    expect(routeSchema.parse("tab.create")).toBe("tab.create");
    expect(routeSchema.parse("tab.select")).toBe("tab.select");
    expect(routeSchema.parse("tab.close")).toBe("tab.close");
    expect(routeSchema.parse("account.bootstrap")).toBe("account.bootstrap");
    expect(routeSchema.parse("account.bootstrap.ready")).toBe("account.bootstrap.ready");
  });

  it("derives matching directional keys and decrypts compressed payloads", async () => {
    const mac = await generateIdentityKeyPair();
    const controller = await generateIdentityKeyPair();
    const sessionId = "session_abcdefghijklmnop";
    const [macKeys, controllerKeys] = await Promise.all([
      deriveSessionKeys({
        privateKey: mac.privateKey,
        peerPublicKey: await exportPublicKey(controller.publicKey),
        pairingSecret: "pairing-secret",
        sessionId,
        role: "mac",
      }),
      deriveSessionKeys({
        privateKey: controller.privateKey,
        peerPublicKey: await exportPublicKey(mac.publicKey),
        pairingSecret: "pairing-secret",
        sessionId,
        role: "controller",
      }),
    ]);
    const payload = {
      tabId: "tab_1",
      text: "building TerminalDB Remote\n".repeat(150),
      rows: 24,
      columns: 80,
      viewport: false,
    };
    const envelope = await encryptEnvelope({
      key: macKeys.send,
      route: "pty.output",
      sessionId,
      generation: 1,
      sequence: 42,
      payload,
      ttlMs: 30_000,
      now: 1_000,
    });
    expect(wireSize(envelope)).toBeLessThan(MAX_WIRE_BYTES);
    await expect(
      decryptEnvelope(controllerKeys.receive, envelope, 2_000),
    ).resolves.toEqual(payload);
  });

  it("rejects expired envelopes", async () => {
    const mac = await generateIdentityKeyPair();
    const controller = await generateIdentityKeyPair();
    const sessionId = "session_abcdefghijklmnop";
    const keys = await deriveSessionKeys({
      privateKey: mac.privateKey,
      peerPublicKey: await exportPublicKey(controller.publicKey),
      pairingSecret: "pairing-secret",
      sessionId,
      role: "mac",
    });
    const envelope = await encryptEnvelope({
      key: keys.send,
      route: "pty.input",
      sessionId,
      generation: 1,
      sequence: 1,
      payload: { tabId: "tab_1", input: "pwd\r" },
      ttlMs: 500,
      now: 1_000,
    });
    await expect(decryptEnvelope(keys.send, envelope, 2_000)).rejects.toThrow(
      "Envelope expired",
    );
  });

  it("uses a unique 96-bit nonce for every encrypted envelope", async () => {
    const mac = await generateIdentityKeyPair();
    const controller = await generateIdentityKeyPair();
    const sessionId = "session_nonce_test";
    const keys = await deriveSessionKeys({
      privateKey: mac.privateKey,
      peerPublicKey: await exportPublicKey(controller.publicKey),
      pairingSecret: "pairing-secret",
      sessionId,
      role: "mac",
    });
    const envelopes = await Promise.all(
      Array.from({ length: 100 }, (_, sequence) =>
        encryptEnvelope({
          key: keys.send,
          route: "health.pong",
          sessionId,
          sourceId: "mac_1",
          destinationId: "controller_1",
          generation: 1,
          sequence,
          payload: { sentAt: sequence },
          ttlMs: 30_000,
          now: 1_000,
        }),
      ),
    );
    expect(new Set(envelopes.map(({ nonce }) => nonce)).size).toBe(100);
    expect(envelopes.every(({ nonce }) => nonce.length === 16)).toBe(true);
  });

  it("authenticates routing metadata and ciphertext", async () => {
    const mac = await generateIdentityKeyPair();
    const controller = await generateIdentityKeyPair();
    const sessionId = "session_tamper_test";
    const keys = await deriveSessionKeys({
      privateKey: mac.privateKey,
      peerPublicKey: await exportPublicKey(controller.publicKey),
      pairingSecret: "pairing-secret",
      sessionId,
      role: "mac",
    });
    const envelope = await encryptEnvelope({
      key: keys.send,
      route: "pty.output",
      sessionId,
      sourceId: "mac_1",
      destinationId: "controller_1",
      generation: 3,
      sequence: 9,
      payload: { tabId: "tab_1", text: "trusted output" },
      ttlMs: 30_000,
      now: 1_000,
    });
    await expect(
      decryptEnvelope(keys.send, { ...envelope, destinationId: "controller_2" }, 2_000),
    ).rejects.toThrow();
    const replacement = envelope.ciphertext.endsWith("A") ? "B" : "A";
    await expect(
      decryptEnvelope(
        keys.send,
        { ...envelope, ciphertext: `${envelope.ciphertext.slice(0, -1)}${replacement}` },
        2_000,
      ),
    ).rejects.toThrow();
  });

  it("rejects payloads that cannot fit in one 30 KB wire envelope", async () => {
    const mac = await generateIdentityKeyPair();
    const controller = await generateIdentityKeyPair();
    const bytes = new Uint8Array(32_000);
    crypto.getRandomValues(bytes);
    const keys = await deriveSessionKeys({
      privateKey: mac.privateKey,
      peerPublicKey: await exportPublicKey(controller.publicKey),
      pairingSecret: "pairing-secret",
      sessionId: "session_size_test",
      role: "mac",
    });
    await expect(
      encryptEnvelope({
        key: keys.send,
        route: "viewport.snapshot",
        sessionId: "session_size_test",
        generation: 1,
        sequence: 1,
        payload: {
          tabId: "tab_1",
          text: Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join(""),
        },
        ttlMs: 30_000,
      }),
    ).rejects.toThrow("Encrypted envelope exceeds 30000 bytes");
  });

  it("inflates the raw DEFLATE vector emitted by the native macOS agent", () => {
    const nativeVector =
      "C0ktys3MS8xxcVJIzs8tKEotLs7Mz1MoS00uyS9SCBmVHZUdlR2VHTSyAA";
    const decoded = new TextDecoder().decode(
      inflateSync(base64UrlDecode(nativeVector)),
    );
    expect(decoded).toBe("TerminalDB compression vector ".repeat(40));
  });

  it("keeps the five-batch cost target below four cents per hour", () => {
    const estimate = estimateWebSocketCost({
      activeHours: 1,
      batchesPerSecond: 5,
      averageWireBytes: 12 * 1024,
    });
    expect(estimate.billableMessages).toBe(36_000);
    expect(estimate.messageCostUsd).toBeCloseTo(0.036);
  });
});
