import { describe, expect, it } from "vitest";

import {
  canAcceptTerminalInput,
  connectionReducer,
  initialConnection,
  presentedConnectionState,
} from "./state";

describe("connection state model", () => {
  it("requires resync before returning live", () => {
    const secured = connectionReducer(initialConnection, { type: "socket-open" });
    expect(secured.state).toBe("resyncing");
    const healthy = connectionReducer(secured, { type: "health", rttMs: 44, at: 10 });
    expect(healthy.state).toBe("resyncing");
    expect(connectionReducer(healthy, { type: "resync-complete", at: 12 }).state).toBe("live");
  });

  it("distinguishes phone and Mac connectivity", () => {
    expect(
      connectionReducer(initialConnection, { type: "socket-close", phoneOffline: true }).state,
    ).toBe("phone-offline");
    expect(connectionReducer(initialConnection, { type: "mac-stale" }).state).toBe("mac-offline");
  });

  it("never models automatic resend as a transition", () => {
    const uncertain = connectionReducer(initialConnection, {
      type: "delivery-uncertain",
      detail: "Checking request id.",
    });
    expect(uncertain.state).toBe("delivery-uncertain");
  });

  it("keeps a previously synchronized terminal usable during background maintenance", () => {
    const secured = connectionReducer(initialConnection, { type: "socket-open" });
    const healthy = connectionReducer(secured, { type: "health", rttMs: 44, at: 10 });
    const live = connectionReducer(healthy, { type: "resync-complete", at: 12 });

    for (const action of [
      { type: "resync-start" } as const,
      { type: "rotation-start" } as const,
    ]) {
      const maintaining = connectionReducer(live, action);
      expect(canAcceptTerminalInput(maintaining)).toBe(true);
      expect(presentedConnectionState(maintaining)).toBe("live");
    }

    const uncertain = connectionReducer(live, {
      type: "delivery-uncertain",
      detail: "Resolving acknowledgement.",
    });
    expect(canAcceptTerminalInput(uncertain)).toBe(false);
    expect(presentedConnectionState(uncertain)).toBe("live");
  });

  it("blocks input when the transport or Mac is actually unavailable", () => {
    const secured = connectionReducer(initialConnection, { type: "socket-open" });
    expect(canAcceptTerminalInput(secured)).toBe(false);
    expect(canAcceptTerminalInput(connectionReducer(secured, { type: "mac-stale" })))
      .toBe(false);
    expect(canAcceptTerminalInput(connectionReducer(secured, { type: "socket-close" })))
      .toBe(false);
  });

  it("does not let a tab switch or connection rotation hide an offline Mac", () => {
    const socketOpen = connectionReducer(initialConnection, { type: "socket-open" });
    const offline = connectionReducer(socketOpen, { type: "mac-stale", at: 50_000 });

    const tabResync = connectionReducer(offline, { type: "resync-start" });
    expect(tabResync.state).toBe("mac-offline");
    expect(tabResync.detail).toMatch(/not reconnected/iu);
    expect(canAcceptTerminalInput(tabResync)).toBe(false);

    const rotating = connectionReducer(offline, { type: "rotation-start" });
    expect(rotating.state).toBe("mac-offline");
    expect(canAcceptTerminalInput(rotating)).toBe(false);
  });

  it("recovers from Mac offline only after fresh health and a completed resync", () => {
    const socketOpen = connectionReducer(initialConnection, { type: "socket-open" });
    const offline = connectionReducer(socketOpen, { type: "mac-stale", at: 50_000 });
    const healthy = connectionReducer(offline, { type: "health", rttMs: 90, at: 60_000 });
    expect(healthy.state).toBe("resyncing");
    const live = connectionReducer(healthy, { type: "resync-complete", at: 60_010 });
    expect(live.state).toBe("live");
    expect(canAcceptTerminalInput(live)).toBe(true);
  });
});
