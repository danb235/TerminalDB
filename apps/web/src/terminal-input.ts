export const MAX_TERMINAL_INPUT_CHUNK_BYTES = 8 * 1024;

export function commandInputForPTY(draft: string): string {
  const normalized = draft
    .replaceAll("\r\n", "\n")
    .replaceAll("\n", "\r");
  return normalized.endsWith("\r") ? normalized : `${normalized}\r`;
}

export const BRACKETED_PASTE_START = "\u001b[200~";
export const BRACKETED_PASTE_END = "\u001b[201~";

/**
 * Text on its way to a PTY. Line endings become carriage returns, the same as
 * typing Return, and a program that asked for bracketed paste receives the
 * markers that tell it this is pasted text rather than a run of commands.
 */
export function pastePayload(text: string, bracketedPaste: boolean): string {
  const normalized = text.replaceAll("\r\n", "\r").replaceAll("\n", "\r");
  if (!normalized) return "";
  return bracketedPaste
    ? `${BRACKETED_PASTE_START}${normalized}${BRACKETED_PASTE_END}`
    : normalized;
}

function utf8Length(character: string): number {
  const codePoint = character.codePointAt(0) ?? 0;
  if (codePoint <= 0x7f) return 1;
  if (codePoint <= 0x7ff) return 2;
  if (codePoint <= 0xffff) return 3;
  return 4;
}

/**
 * Keep each remote input envelope comfortably below the protocol wire limit.
 * Iterating a string uses Unicode code points, so a multi-byte scalar is never
 * divided between two WebSocket messages.
 */
export function terminalInputChunks(
  input: string,
  maximumBytes = MAX_TERMINAL_INPUT_CHUNK_BYTES,
): string[] {
  if (input.length === 0) return [];
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes < 4) {
    throw new RangeError("maximumBytes must fit at least one Unicode scalar");
  }

  const chunks: string[] = [];
  let chunk = "";
  let chunkBytes = 0;
  for (const character of input) {
    const characterBytes = utf8Length(character);
    if (chunkBytes > 0 && chunkBytes + characterBytes > maximumBytes) {
      chunks.push(chunk);
      chunk = "";
      chunkBytes = 0;
    }
    chunk += character;
    chunkBytes += characterBytes;
  }
  if (chunk.length > 0) chunks.push(chunk);
  return chunks;
}
