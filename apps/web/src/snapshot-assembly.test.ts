import { describe, expect, it } from "vitest";

import { SnapshotAssembler } from "./snapshot-assembly";

describe("viewport snapshot assembly", () => {
  it("reassembles bounded chunks in arrival order", () => {
    const assembler = new SnapshotAssembler();
    expect(assembler.accept({
      tabId: "tab-1",
      snapshotId: "snapshot-1",
      chunkIndex: 1,
      chunkCount: 3,
      text: "middle",
    })).toBeUndefined();
    expect(assembler.accept({
      tabId: "tab-1",
      snapshotId: "snapshot-1",
      chunkIndex: 0,
      chunkCount: 3,
      text: "start-",
    })).toBeUndefined();
    expect(assembler.accept({
      tabId: "tab-1",
      snapshotId: "snapshot-1",
      chunkIndex: 2,
      chunkCount: 3,
      text: "-end",
    })).toBe("start-middle-end");
  });

  it("ignores duplicate chunks without completing early", () => {
    const assembler = new SnapshotAssembler();
    const first = {
      tabId: "tab-1",
      snapshotId: "snapshot-1",
      chunkIndex: 0,
      chunkCount: 2,
      text: "first",
    } as const;
    expect(assembler.accept(first)).toBeUndefined();
    expect(assembler.accept(first)).toBeUndefined();
    expect(assembler.accept({ ...first, chunkIndex: 1, text: "second" }))
      .toBe("firstsecond");
  });

  it("rejects unbounded and inconsistent snapshots", () => {
    const assembler = new SnapshotAssembler();
    expect(() => assembler.accept({
      tabId: "tab-1",
      snapshotId: "snapshot-1",
      chunkIndex: 0,
      chunkCount: 65,
      text: "x",
    })).toThrow(/Invalid/u);
    expect(assembler.accept({
      tabId: "tab-1",
      snapshotId: "snapshot-2",
      chunkIndex: 0,
      chunkCount: 2,
      text: "x",
    })).toBeUndefined();
    expect(() => assembler.accept({
      tabId: "tab-1",
      snapshotId: "snapshot-2",
      chunkIndex: 1,
      chunkCount: 3,
      text: "y",
    })).toThrow(/count changed/u);
  });

  it("keeps delayed chunks long enough to survive a poor mobile connection", () => {
    let now = 10_000;
    const assembler = new SnapshotAssembler(() => now);
    expect(assembler.accept({
      tabId: "tab-1",
      snapshotId: "slow-snapshot",
      chunkIndex: 0,
      chunkCount: 2,
      text: "first",
    })).toBeUndefined();
    now += 20_000;
    expect(assembler.accept({
      tabId: "tab-1",
      snapshotId: "slow-snapshot",
      chunkIndex: 1,
      chunkCount: 2,
      text: "second",
    })).toBe("firstsecond");
  });

  it("expires abandoned assemblies so reconnect churn remains bounded", () => {
    let now = 10_000;
    const assembler = new SnapshotAssembler(() => now);
    expect(assembler.accept({
      tabId: "tab-1",
      snapshotId: "expired-snapshot",
      chunkIndex: 0,
      chunkCount: 2,
      text: "old",
    })).toBeUndefined();
    now += 31_000;
    expect(assembler.accept({
      tabId: "tab-1",
      snapshotId: "expired-snapshot",
      chunkIndex: 1,
      chunkCount: 2,
      text: "new",
    })).toBeUndefined();
  });
});
