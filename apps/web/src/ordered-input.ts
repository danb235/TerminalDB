interface InputLane {
  tail: Promise<void>;
  blocked: boolean;
  cancelled: boolean;
}

export type InputDeliveryResult = "delivered" | "discarded";

/**
 * API Gateway invokes the relay Lambda independently for every WebSocket
 * message, so two messages sent in order are not enough to guarantee that
 * two PTY writes reach the Mac in order. Each tab therefore has an
 * acknowledgement barrier: the next batch is not put on the wire until the
 * Mac has accepted the previous one.
 */
export class AcknowledgedInputQueue {
  readonly #lanes = new Map<string, InputLane>();

  enqueue(
    tabId: string,
    deliver: () => Promise<unknown>,
  ): Promise<InputDeliveryResult> {
    let lane = this.#lanes.get(tabId);
    if (!lane) {
      lane = {
        tail: Promise.resolve(),
        blocked: false,
        cancelled: false,
      };
      this.#lanes.set(tabId, lane);
    }
    const activeLane = lane;
    const operation = activeLane.tail.then(async () => {
      if (activeLane.blocked || activeLane.cancelled) return "discarded" as const;
      try {
        await deliver();
        return "delivered" as const;
      } catch (error) {
        activeLane.blocked = true;
        throw error;
      }
    });
    // Always settle the barrier so already-queued work can observe the
    // blocked flag and be discarded instead of becoming an unhandled promise.
    activeLane.tail = operation.then(
      () => undefined,
      () => undefined,
    );
    return operation;
  }

  cancel(tabId: string): void {
    const lane = this.#lanes.get(tabId);
    if (lane) lane.cancelled = true;
    this.#lanes.delete(tabId);
  }

  cancelAll(): void {
    for (const lane of this.#lanes.values()) lane.cancelled = true;
    this.#lanes.clear();
  }
}
