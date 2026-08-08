interface InputLane {
  readonly streamId: string;
  nextSequence: number;
  tail: Promise<void>;
  blocked: boolean;
  cancelled: boolean;
}

export type InputDeliveryResult = "delivered" | "discarded";

export interface SequencedInputBatch {
  readonly input: string;
  readonly inputStreamId: string;
  readonly inputSequence: number;
}

/**
 * API Gateway invokes the relay Lambda independently for every WebSocket
 * message, so wire order is not sufficient. Batches carry a per-tab stream
 * sequence that the Mac reorders before writing to the PTY. This lets the
 * browser pipeline input instead of limiting typing throughput to one batch
 * per network round trip.
 */
export class AcknowledgedInputQueue {
  readonly #lanes = new Map<string, InputLane>();

  enqueue(
    tabId: string,
    input: string,
    deliver: (batch: SequencedInputBatch) => Promise<unknown>,
    pipelined = false,
  ): Promise<InputDeliveryResult> {
    let lane = this.#lanes.get(tabId);
    if (!lane) {
      lane = {
        streamId: crypto.randomUUID(),
        nextSequence: 1,
        tail: Promise.resolve(),
        blocked: false,
        cancelled: false,
      };
      this.#lanes.set(tabId, lane);
    }
    const activeLane = lane;
    if (activeLane.blocked || activeLane.cancelled) {
      return Promise.resolve("discarded");
    }
    const batch: SequencedInputBatch = {
      input,
      inputStreamId: activeLane.streamId,
      inputSequence: activeLane.nextSequence,
    };
    activeLane.nextSequence += 1;
    const execute = () => deliver(batch).then(
      () => "delivered" as const,
      (error: unknown) => {
        activeLane.blocked = true;
        throw error;
      },
    );
    const operation = pipelined
      ? execute()
      : activeLane.tail.then(() => {
          if (activeLane.blocked || activeLane.cancelled) return "discarded" as const;
          return execute();
        });
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
