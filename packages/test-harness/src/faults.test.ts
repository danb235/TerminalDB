import { describe, expect, it } from "vitest";

import { FaultyRelay, MockMac, type SideEffectRequest } from "./faults";

function command(overrides: Partial<SideEffectRequest> = {}): SideEffectRequest {
  return {
    requestId: "request_1",
    generation: 1,
    expiresAt: 2_000,
    input: "npm test\r",
    ...overrides,
  };
}

describe("fault-injected remote delivery", () => {
  it("executes duplicated terminal input exactly once", () => {
    const mac = new MockMac();
    const relay = new FaultyRelay<SideEffectRequest>();
    relay.duplicateNext = true;
    const results = relay.deliver(command()).map((request) => mac.accept(request, 1_000));
    expect(results).toEqual([
      { accepted: true, duplicate: false },
      { accepted: true, duplicate: true },
    ]);
    expect(mac.executedInputs).toEqual(["npm test\r"]);
  });

  it("rejects expired input and an old session generation", () => {
    const mac = new MockMac();
    expect(mac.accept(command({ expiresAt: 900 }), 1_000).detail).toBe("expired");
    mac.restart();
    expect(mac.accept(command(), 1_000).detail).toBe("stale-generation");
    expect(mac.executedInputs).toEqual([]);
  });

  it("models a lost acknowledgement as uncertain without automatic resend", () => {
    const mac = new MockMac();
    expect(mac.accept(command(), 1_000).accepted).toBe(true);
    const acknowledgement = new FaultyRelay<{ requestId: string }>();
    acknowledgement.dropNext = true;
    expect(acknowledgement.deliver({ requestId: "request_1" })).toEqual([]);

    // Resync queries the deduplication record; it does not resend terminal input.
    expect(mac.status("request_1")).toEqual({
      accepted: true,
      duplicate: true,
    });
    expect(mac.executedInputs).toEqual(["npm test\r"]);
  });

  it("drops delivery to a stale destination mapping", () => {
    const relay = new FaultyRelay<SideEffectRequest>();
    relay.destinationStale = true;
    expect(relay.deliver(command())).toEqual([]);
  });
});
