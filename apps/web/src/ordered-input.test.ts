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
  it("does not put Return on the wire before every earlier character is accepted", async () => {
    const queue = new AcknowledgedInputQueue();
    const first = deferred();
    const sent: string[] = [];
    const printable = queue.enqueue("tab", async () => {
      sent.push("pw");
      await first.promise;
    });
    const commit = queue.enqueue("tab", async () => {
      sent.push("d\r");
    });

    await Promise.resolve();
    expect(sent).toEqual(["pw"]);
    first.resolve();
    await expect(printable).resolves.toBe("delivered");
    await expect(commit).resolves.toBe("delivered");
    expect(sent.join("")).toBe("pwd\r");
  });

  it("discards later input when an earlier batch is uncertain", async () => {
    const queue = new AcknowledgedInputQueue();
    const failure = new Error("acknowledgement lost");
    const later = vi.fn(async () => undefined);
    const first = queue.enqueue("tab", async () => {
      throw failure;
    });
    const second = queue.enqueue("tab", later);

    await expect(first).rejects.toThrow("acknowledgement lost");
    await expect(second).resolves.toBe("discarded");
    expect(later).not.toHaveBeenCalled();
  });

  it("keeps independent tabs independent", async () => {
    const queue = new AcknowledgedInputQueue();
    const blocked = deferred();
    const sent: string[] = [];
    void queue.enqueue("one", async () => {
      sent.push("one");
      await blocked.promise;
    });
    await queue.enqueue("two", async () => {
      sent.push("two");
    });
    expect(sent).toEqual(["one", "two"]);
    blocked.resolve();
  });
});
