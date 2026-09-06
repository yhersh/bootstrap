#!/usr/bin/env node
import { spawnSync } from "node:child_process";

const pwsh = spawnSync("pwsh", ["-NoLogo", "-NoProfile", "-Command", "$PSVersionTable.PSVersion"], {
  encoding: "utf8",
});

if (pwsh.status !== 0) {
  if (process.env.CI === "true") {
    console.error("pwsh not available; Windows tests are required in CI.");
    process.exit(1);
  }

  console.log("pwsh not available; skipping Windows tests.");
  process.exit(0);
}

const pester = spawnSync(
  "pwsh",
  [
    "-NoLogo",
    "-NoProfile",
    "-Command",
    "Invoke-Pester -Path ./test/windows.Tests.ps1 -Output Detailed -PassThru | ForEach-Object { if ($_.FailedCount -gt 0) { exit 1 } }",
  ],
  { stdio: "inherit" },
);

process.exit(pester.status ?? 1);
