import type { RemoteInputMode } from "@terminaldb/protocol";

export interface OptimisticInputRender {
  readonly rendered: string;
  readonly expectedEcho: string;
  readonly editableCells: number;
}

export interface EchoReconciliation {
  readonly expectedEcho: string;
  readonly output: string;
  readonly mismatch: boolean;
}

function isPrintable(character: string): boolean {
  const codePoint = character.codePointAt(0);
  return codePoint !== undefined && codePoint >= 0x20 && codePoint !== 0x7f;
}

/**
 * Returns the visual input that can be painted before the Mac responds.
 * Unsupported control sequences are deliberately all-or-nothing so an ANSI
 * key sequence can never be partially rendered as terminal text.
 */
export function optimisticRenderForInput(
  input: string,
  mode: RemoteInputMode,
  editableCells = 0,
): OptimisticInputRender | undefined {
  if (!input || mode === "secure") return undefined;

  let rendered = "";
  let nextEditableCells = Math.max(0, editableCells);
  for (const character of input) {
    if (isPrintable(character)) {
      rendered += character;
      nextEditableCells += 1;
    } else if (character === "\b" || character === "\x7f") {
      // The browser owns only the speculative characters it painted. The
      // prompt and authoritative terminal content are never editable here.
      if (nextEditableCells > 0) {
        rendered += "\b \b";
        nextEditableCells -= 1;
      }
    } else if (character === "\r" && mode === "echo") {
      rendered += "\r\n";
      nextEditableCells = 0;
    } else {
      return undefined;
    }
  }

  return {
    rendered,
    expectedEcho: mode === "echo" ? rendered : "",
    editableCells: nextEditableCells,
  };
}

/**
 * Removes only a byte-for-byte prefix already painted in the browser. A
 * mismatch is never guessed through: the caller must rebuild from its saved
 * authoritative terminal stream and request a fresh viewport.
 */
export function reconcileOptimisticEcho(
  expectedEcho: string,
  output: string,
): EchoReconciliation {
  if (!expectedEcho || !output) {
    return { expectedEcho, output, mismatch: false };
  }

  const maximum = Math.min(expectedEcho.length, output.length);
  let matched = 0;
  while (
    matched < maximum &&
    expectedEcho.charCodeAt(matched) === output.charCodeAt(matched)
  ) {
    matched += 1;
  }

  if (matched === 0 || (matched < maximum && matched < expectedEcho.length)) {
    return { expectedEcho, output, mismatch: true };
  }

  return {
    expectedEcho: expectedEcho.slice(matched),
    output: output.slice(matched),
    mismatch: false,
  };
}
