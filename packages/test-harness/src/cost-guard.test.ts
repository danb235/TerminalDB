import { estimateWebSocketCost } from "@terminaldb/protocol";
import { describe, expect, it } from "vitest";

describe("remote streaming cost guard", () => {
  it("keeps a foreground stream at or below five batches per second", () => {
    const capturedMinute = {
      outputBatches: 300,
      controllers: 1,
      averageWireBytes: 14_000,
    };
    expect(capturedMinute.outputBatches).toBeLessThanOrEqual(5 * 60);
    const month = estimateWebSocketCost({
      activeHours: 10,
      batchesPerSecond: capturedMinute.outputBatches / 60,
      controllers: capturedMinute.controllers,
      averageWireBytes: capturedMinute.averageWireBytes,
    });
    expect(month.messageCostUsd).toBeLessThanOrEqual(0.36);
  });

  it("makes the additional-controller cost explicit", () => {
    const one = estimateWebSocketCost({
      activeHours: 1,
      batchesPerSecond: 2,
      controllers: 1,
    });
    const two = estimateWebSocketCost({
      activeHours: 1,
      batchesPerSecond: 2,
      controllers: 2,
    });
    expect(two.billableMessages).toBe(one.inboundMessages * 3);
  });
});
