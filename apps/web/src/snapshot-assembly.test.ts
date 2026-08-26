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
      chunkCount: 2049,
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

  it("preserves a large colored native viewport beyond the old 64-chunk ceiling", () => {
    const assembler = new SnapshotAssembler();
    const chunk = "\x1b[0;38;2;255;120;20;48;2;12;23;34mX".repeat(100);
    for (let index = 0; index < 100; index += 1) {
      const result = assembler.accept({ tabId: "large", snapshotId: "colored", chunkIndex: index, chunkCount: 100, text: chunk });
      expect(result).toBe(index === 99 ? chunk.repeat(100) : undefined);
    }
  });

  it("bounds both each chunk and aggregate memory across incomplete snapshots", () => {
    const assembler = new SnapshotAssembler();
    expect(() => assembler.accept({ snapshotId: "oversized", chunkIndex: 0, chunkCount: 2, text: "x".repeat(4097) })).toThrow(/Invalid/u);
    expect(() => assembler.accept({ text: "x".repeat(8 * 1024 * 1024 + 1) })).toThrow(/too large/u);
    const text = "x".repeat(4096);
    for (let index = 0; index < 2047; index += 1) {
      assembler.accept({ snapshotId: "first", chunkIndex: index, chunkCount: 2048, text });
    }
    assembler.accept({ snapshotId: "second", chunkIndex: 0, chunkCount: 2, text });
    expect(() => assembler.accept({ snapshotId: "second", chunkIndex: 1, chunkCount: 2, text })).toThrow(/buffer limit/u);
    expect(assembler.accept({ snapshotId: "recovery", chunkIndex: 0, chunkCount: 2, text: "a" })).toBeUndefined();
    expect(assembler.accept({ snapshotId: "recovery", chunkIndex: 1, chunkCount: 2, text: "b" })).toBe("ab");
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
