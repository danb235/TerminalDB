export function commandInputForPTY(draft: string): string {
  const normalized = draft
    .replaceAll("\r\n", "\n")
    .replaceAll("\n", "\r");
  return normalized.endsWith("\r") ? normalized : `${normalized}\r`;
}
