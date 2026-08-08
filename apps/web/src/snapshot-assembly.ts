import type { PTYOutputPayload } from "@terminaldb/protocol";

interface SnapshotAssembly {
  readonly chunks: Array<string | undefined>;
  readonly createdAt: number;
  received: number;
}

export class SnapshotAssembler {
  readonly #snapshots = new Map<string, SnapshotAssembly>();
  readonly #now: () => number;

  constructor(now: () => number = Date.now) {
    this.#now = now;
  }

  accept(candidate: Partial<PTYOutputPayload>): string | undefined {
    this.#prune();
    const chunkCount = candidate.chunkCount ?? 1;
    const chunkIndex = candidate.chunkIndex ?? 0;
    const snapshotId = candidate.snapshotId;
    const text = candidate.text ?? "";
    if (chunkCount === 1) return text;
    if (
      !snapshotId ||
      !Number.isInteger(chunkCount) ||
      chunkCount < 2 ||
      chunkCount > 64 ||
      !Number.isInteger(chunkIndex) ||
      chunkIndex < 0 ||
      chunkIndex >= chunkCount
    ) {
      throw new Error("Invalid viewport snapshot chunk");
    }
    const key = `${candidate.tabId ?? ""}:${snapshotId}`;
    let assembly = this.#snapshots.get(key);
    if (!assembly) {
      if (this.#snapshots.size >= 8) {
        const oldest = this.#snapshots.keys().next().value as string | undefined;
        if (oldest) this.#snapshots.delete(oldest);
      }
      assembly = {
        chunks: new Array<string | undefined>(chunkCount),
        createdAt: this.#now(),
        received: 0,
      };
      this.#snapshots.set(key, assembly);
    }
    if (assembly.chunks.length !== chunkCount) {
      this.#snapshots.delete(key);
      throw new Error("Viewport snapshot chunk count changed");
    }
    if (assembly.chunks[chunkIndex] === undefined) {
      assembly.chunks[chunkIndex] = text;
      assembly.received += 1;
    }
    if (assembly.received !== chunkCount) return undefined;
    const complete = assembly.chunks.join("");
    this.#snapshots.delete(key);
    return complete;
  }

  clear(): void {
    this.#snapshots.clear();
  }

  #prune(): void {
    const cutoff = this.#now() - 30_000;
    for (const [key, assembly] of this.#snapshots) {
      if (assembly.createdAt < cutoff) this.#snapshots.delete(key);
    }
  }
}
