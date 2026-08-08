import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export interface TerminalDBRemoteLocalConfig {
  readonly budgetEmail?: string;
}

export function readLocalConfig(
  directory = process.cwd(),
  configuredPath = process.env.TERMINALDB_REMOTE_CONFIG,
): TerminalDBRemoteLocalConfig {
  const path = resolve(directory, configuredPath ?? "terminaldb-remote.local.json");
  if (!existsSync(path)) return {};

  let parsed: unknown;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch (error) {
    throw new Error(`Unable to parse TerminalDB Remote local config at ${path}`, {
      cause: error,
    });
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new Error(`TerminalDB Remote local config at ${path} must be a JSON object`);
  }

  const budgetEmail = (parsed as Record<string, unknown>).budgetEmail;
  if (budgetEmail === undefined) return {};
  if (
    typeof budgetEmail !== "string" ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(budgetEmail)
  ) {
    throw new Error(`budgetEmail in ${path} must be a valid email address`);
  }
  return { budgetEmail };
}
