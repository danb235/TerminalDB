import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export interface TerminalDBRemoteLocalConfig {
  readonly budgetEmail?: string;
  readonly domainName?: string;
  readonly certificateArn?: string;
  readonly authDomainName?: string;
  readonly authCertificateArn?: string;
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

  const values = parsed as Record<string, unknown>;
  const budgetEmail = values.budgetEmail;
  if (
    budgetEmail !== undefined && (
    typeof budgetEmail !== "string" ||
    !/^[^\s@]+@[^\s@]+\.[^\s@]+$/u.test(budgetEmail)
    )
  ) {
    throw new Error(`budgetEmail in ${path} must be a valid email address`);
  }
  const domain = (key: "domainName" | "authDomainName"): string | undefined => {
    const value = values[key];
    if (value === undefined) return undefined;
    if (typeof value !== "string" || !/^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/u.test(value)) {
      throw new Error(`${key} in ${path} must be a valid lowercase DNS name`);
    }
    return value;
  };
  const certificate = (
    key: "certificateArn" | "authCertificateArn",
  ): string | undefined => {
    const value = values[key];
    if (value === undefined) return undefined;
    if (typeof value !== "string" || !/^arn:aws:acm:us-east-1:\d{12}:certificate\/[\w-]+$/u.test(value)) {
      throw new Error(`${key} in ${path} must be a us-east-1 ACM certificate ARN`);
    }
    return value;
  };
  const domainName = domain("domainName");
  const certificateArn = certificate("certificateArn");
  const authDomainName = domain("authDomainName");
  const authCertificateArn = certificate("authCertificateArn");
  return {
    ...(typeof budgetEmail === "string" ? { budgetEmail } : {}),
    ...(domainName ? { domainName } : {}),
    ...(certificateArn ? { certificateArn } : {}),
    ...(authDomainName ? { authDomainName } : {}),
    ...(authCertificateArn ? { authCertificateArn } : {}),
  };
}
