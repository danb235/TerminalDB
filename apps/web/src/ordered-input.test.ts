import { describe, expect, it, vi } from "vitest";

import { AcknowledgedInputQueue } from "./ordered-input";

function deferred() {
  let resolve!: () => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<void>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

describe("acknowledged terminal input queue", () => {
  it("pipelines input while assigning a stable ordered stream", async () => {
    const queue = new AcknowledgedInputQueue();
    const first = deferred();
    const sent: Array<{ input: string; stream: string; sequence: number }> = [];
    const printable = queue.enqueue("tab", "pw", async (batch) => {
      sent.push({
        input: batch.input,
        stream: batch.inputStreamId,
        sequence: batch.inputSequence,
      });
      await first.promise;
    }, true);
    const commit = queue.enqueue("tab", "d\r", async (batch) => {
      sent.push({
        input: batch.input,
        stream: batch.inputStreamId,
        sequence: batch.inputSequence,
      });
    }, true);

    await Promise.resolve();
    expect(sent.map(({ input }) => input)).toEqual(["pw", "d\r"]);
    expect(sent.map(({ sequence }) => sequence)).toEqual([1, 2]);
    expect(new Set(sent.map(({ stream }) => stream)).size).toBe(1);
    first.resolve();
    await expect(printable).resolves.toBe("delivered");
    await expect(commit).resolves.toBe("delivered");
  });

  it("keeps the acknowledgement barrier for an older Mac agent", async () => {
    const queue = new AcknowledgedInputQueue();
    const first = deferred();
    const sent: string[] = [];
    const earlier = queue.enqueue("tab", "a", async (batch) => {
      sent.push(batch.input);
      await first.promise;
    });
    const later = queue.enqueue("tab", "b", async (batch) => {
      sent.push(batch.input);
    });

    await Promise.resolve();
    expect(sent).toEqual(["a"]);
    first.resolve();
    await expect(earlier).resolves.toBe("delivered");
    await expect(later).resolves.toBe("delivered");
    expect(sent).toEqual(["a", "b"]);
  });

  it("discards later input when an earlier batch is uncertain", async () => {
    const queue = new AcknowledgedInputQueue();
    const failure = new Error("acknowledgement lost");
    const later = vi.fn(async () => undefined);
    const first = queue.enqueue("tab", "first", async () => {
      throw failure;
    });
    await expect(first).rejects.toThrow("acknowledgement lost");
    const second = queue.enqueue("tab", "later", later);
    await expect(second).resolves.toBe("discarded");
    expect(later).not.toHaveBeenCalled();
  });

  it("keeps independent tabs independent", async () => {
    const queue = new AcknowledgedInputQueue();
    const blocked = deferred();
    const sent: string[] = [];
    void queue.enqueue("one", "one", async () => {
      sent.push("one");
      await blocked.promise;
    });
    await queue.enqueue("two", "two", async () => {
      sent.push("two");
    });
    expect(sent).toEqual(["one", "two"]);
    blocked.resolve();
  });
});
