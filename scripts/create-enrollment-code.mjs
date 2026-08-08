#!/usr/bin/env node
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function argument(name, fallback) {
  const index = process.argv.indexOf(`--${name}`);
  return index >= 0 && process.argv[index + 1] ? process.argv[index + 1] : fallback;
}

const profile = argument("profile", "stelao");
const region = argument("region", "us-west-2");
const stage = argument("stage", "dev");
const stackName = argument("stack", `TerminalDBRemote-${stage}`);
let functionName = argument("function-name");

const aws = (...args) =>
  execFileSync("aws", [...args, "--profile", profile, "--region", region], {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
  }).trim();

if (!functionName) {
  functionName = aws(
    "cloudformation",
    "describe-stacks",
    "--stack-name",
    stackName,
    "--query",
    "Stacks[0].Outputs[?OutputKey=='ControlFunctionName'].OutputValue | [0]",
    "--output",
    "text",
  );
}
if (!functionName || functionName === "None") {
  throw new Error(`Could not find ControlFunctionName in ${stackName}`);
}

const temporaryDirectory = mkdtempSync(join(tmpdir(), "terminaldb-enrollment-"));
const responsePath = join(temporaryDirectory, "response.json");
try {
  aws(
    "lambda",
    "invoke",
    "--function-name",
    functionName,
    "--cli-binary-format",
    "raw-in-base64-out",
    "--payload",
    '{"action":"createEnrollment"}',
    responsePath,
  );
  const response = JSON.parse(readFileSync(responsePath, "utf8"));
  if (!response.enrollmentCode) throw new Error(`Unexpected Lambda response: ${JSON.stringify(response)}`);
  process.stdout.write(
    [
      "TerminalDB one-time enrollment code",
      "",
      response.enrollmentCode,
      "",
      `Expires: ${new Date(response.expiresAt * 1000).toLocaleString()}`,
      "This code is shown once. Paste it into TerminalDB on the Mac being enrolled.",
      "",
    ].join("\n"),
  );
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}
