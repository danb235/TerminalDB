const encoder = new TextEncoder();
const decoder = new TextDecoder();

export function utf8(value: string): Uint8Array {
  return encoder.encode(value);
}

export function text(value: Uint8Array): string {
  return decoder.decode(value);
}

export function base64UrlEncode(value: Uint8Array): string {
  let binary = "";
  for (const byte of value) binary += String.fromCharCode(byte);
  return btoa(binary)
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replace(/=+$/u, "");
}

export function base64UrlDecode(value: string): Uint8Array {
  const base64 = value.replaceAll("-", "+").replaceAll("_", "/");
  const padded = base64.padEnd(Math.ceil(base64.length / 4) * 4, "=");
  const binary = atob(padded);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function wireSize(value: unknown): number {
  return utf8(JSON.stringify(value)).byteLength;
}

export function randomIdentifier(bytes = 18): string {
  const value = new Uint8Array(bytes);
  crypto.getRandomValues(value);
  return base64UrlEncode(value);
}
