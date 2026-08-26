export function adaptSnapshotToLocalViewport(
  text: string,
  remoteRows: number,
  localRows: number,
  localColumns: number,
): string {
  // SwiftTerm snapshots retain the active rendition for subsequent PTY deltas.
  // A wrap-pending cursor also repaints the final glyph before restoring SGR.
  // Accept legacy snapshots without this tail as well.
  const cursorSuffix = /\x1b\[0m\x1b\[(\d+);(\d+)H(\x1b\[\?25[hl])((?:\x1b\[[\d;:]*m[^\x1b]*)*)$/u;
  return text.replace(
    cursorSuffix,
    (_match, rowText: string, columnText: string, visibility: string, rendition = "") => {
      const remoteRow = Math.max(1, Number.parseInt(rowText, 10));
      const remoteColumn = Math.max(1, Number.parseInt(columnText, 10));
      const distanceFromBottom = Math.max(0, remoteRows - remoteRow);
      const localRow = Math.max(1, Math.min(localRows, localRows - distanceFromBottom));
      const localColumn = Math.max(1, Math.min(localColumns, remoteColumn));
      return `\x1b[0m\x1b[${localRow};${localColumn}H${visibility}${rendition}`;
    },
  );
}
