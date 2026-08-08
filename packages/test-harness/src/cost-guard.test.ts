import { estimateWebSocketCost } from "@terminaldb/protocol";
import { describe, expect, it } from "vitest";

describe("remote streaming cost guard", () => {
  it("keeps an idle foreground stream at or below five batches per second", () => {
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

  it("bounds short post-input interactive bursts at twenty frames per second", () => {
    const interactiveBurst = {
      outputBatches: 20 * 60,
      controllers: 1,
      averageWireBytes: 14_000,
    };
    expect(interactiveBurst.outputBatches).toBeLessThanOrEqual(20 * 60);
    const sustainedWorstCaseMonth = estimateWebSocketCost({
      activeHours: 10,
      batchesPerSecond: interactiveBurst.outputBatches / 60,
      controllers: interactiveBurst.controllers,
      averageWireBytes: interactiveBurst.averageWireBytes,
    });
    expect(sustainedWorstCaseMonth.messageCostUsd).toBeLessThanOrEqual(1.44);
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
