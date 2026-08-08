export interface SideEffectRequest {
  readonly requestId: string;
  readonly generation: number;
  readonly expiresAt: number;
  readonly input: string;
}

export interface Acceptance {
  readonly accepted: boolean;
  readonly duplicate: boolean;
  readonly detail?: string;
}

export class MockMac {
  #generation: number;
  readonly #accepted = new Set<string>();
  readonly executedInputs: string[] = [];

  constructor(generation = 1) {
    this.#generation = generation;
  }

  get generation(): number {
    return this.#generation;
  }

  accept(request: SideEffectRequest, now: number): Acceptance {
    if (request.expiresAt < now) {
      return { accepted: false, duplicate: false, detail: "expired" };
    }
    if (request.generation !== this.#generation) {
      return { accepted: false, duplicate: false, detail: "stale-generation" };
    }
    if (this.#accepted.has(request.requestId)) {
      return { accepted: true, duplicate: true };
    }
    this.#accepted.add(request.requestId);
    this.executedInputs.push(request.input);
    return { accepted: true, duplicate: false };
  }

  status(requestId: string): Acceptance | undefined {
    return this.#accepted.has(requestId)
      ? { accepted: true, duplicate: true }
      : undefined;
  }

  restart(): void {
    this.#generation += 1;
    this.#accepted.clear();
  }
}

export class FaultyRelay<T> {
  dropNext = false;
  duplicateNext = false;
  destinationStale = false;

  deliver(value: T): readonly T[] {
    if (this.destinationStale || this.dropNext) {
      this.dropNext = false;
      return [];
    }
    if (this.duplicateNext) {
      this.duplicateNext = false;
      return [value, value];
    }
    return [value];
  }
}
