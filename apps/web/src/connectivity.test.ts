import { describe, expect, it } from "vitest";

import {
  CONNECTION_ROTATION_MS,
  controllerDeviceName,
  endedSessionReason,
  fullJitterReconnectDelay,
  hasSequenceGap,
  IDLE_HEALTH_INTERVAL_MS,
  MAC_OFFLINE_AFTER_MS,
  MAC_STALE_AFTER_MS,
  RECONNECT_DELAYS_MS,
  ROTATION_HANDOVER_MS,
  synchronizationReady,
} from "./remote-client";

describe("connectivity timing contract", () => {
  it("keeps idle health safely below the API Gateway idle timeout", () => {
    expect(IDLE_HEALTH_INTERVAL_MS).toBe(4 * 60 * 1_000);
    expect(IDLE_HEALTH_INTERVAL_MS).toBeLessThan(10 * 60 * 1_000);
    expect(MAC_STALE_AFTER_MS).toBe(45_000);
    expect(MAC_OFFLINE_AFTER_MS).toBe(60_000);
    expect(MAC_STALE_AFTER_MS).toBeLessThan(MAC_OFFLINE_AFTER_MS);
  });

  it("rotates before the two-hour WebSocket lifetime with a handover grace period", () => {
    expect(CONNECTION_ROTATION_MS).toBe(110 * 60 * 1_000);
    expect(CONNECTION_ROTATION_MS).toBeLessThan(2 * 60 * 60 * 1_000);
    expect(ROTATION_HANDOVER_MS).toBe(30_000);
  });

  it("uses bounded full jitter and caps retries at 30 seconds", () => {
    expect(RECONNECT_DELAYS_MS).toEqual([
      500,
      1_000,
      2_000,
      4_000,
      8_000,
      15_000,
      30_000,
    ]);
    expect(fullJitterReconnectDelay(0, 0)).toBe(0);
    expect(fullJitterReconnectDelay(0, 1)).toBe(500);
    expect(fullJitterReconnectDelay(3, 0.5)).toBe(2_000);
    expect(fullJitterReconnectDelay(999, 1)).toBe(30_000);
  });

  it("does not report synchronization before health and the selected viewport arrive", () => {
    expect(
      synchronizationReady({
        inventory: true,
        health: true,
        viewportRequired: true,
        viewport: false,
        uncertainRequests: 0,
      }),
    ).toBe(false);
    expect(
      synchronizationReady({
        inventory: true,
        health: true,
        viewportRequired: true,
        viewport: true,
        uncertainRequests: 1,
      }),
    ).toBe(false);
    expect(
      synchronizationReady({
        inventory: true,
        health: true,
        viewportRequired: true,
        viewport: true,
        uncertainRequests: 0,
      }),
    ).toBe(true);
  });

  it("detects missing relay messages without treating the first observation as a gap", () => {
    expect(hasSequenceGap(0, 84_000)).toBe(false);
    expect(hasSequenceGap(84_000, 84_001)).toBe(false);
    expect(hasSequenceGap(84_000, 84_002)).toBe(true);
    expect(hasSequenceGap(84_002, 84_001)).toBe(false);
  });

  it("labels trusted controllers without assuming every phone is an iPhone", () => {
    expect(controllerDeviceName("Mozilla/5.0 (iPhone) Safari")).toBe("iPhone");
    expect(controllerDeviceName("Mozilla/5.0 (Linux; Android 15) Chrome")).toBe(
      "Android phone",
    );
    expect(controllerDeviceName("Mozilla/5.0 Chrome")).toBe("Web browser");
  });

  it("turns terminal ticket failures into a final customer-facing session state", () => {
    expect(endedSessionReason(410, "Session ended")).toBe("remote-ended");
    expect(endedSessionReason(404, "Active session not found")).toBe("remote-ended");
    expect(endedSessionReason(401, "Controller revoked")).toBe("controller-revoked");
    expect(endedSessionReason(503, "Temporary upstream failure")).toBeUndefined();
  });
});
