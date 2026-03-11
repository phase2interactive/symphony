import { defineConfig, devices } from "@playwright/test";
import { readFileSync } from "fs";
import { resolve } from "path";

// Load .env file so SYMPHONY_GITHUB_TOKEN is available to both
// the Playwright test process and the webServer child process.
try {
  const envPath = resolve(__dirname, ".env");
  const envContent = readFileSync(envPath, "utf8");
  for (const line of envContent.split("\n")) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;
    const eqIndex = trimmed.indexOf("=");
    if (eqIndex === -1) continue;
    const key = trimmed.slice(0, eqIndex);
    const value = trimmed.slice(eqIndex + 1);
    if (!process.env[key]) process.env[key] = value;
  }
} catch {
  // .env is optional — token may come from the environment directly
}

/**
 * Playwright configuration for Symphony's Phoenix observability dashboard.
 *
 * The webServer starts Symphony with SYMPHONY_GITHUB_TOKEN from the environment.
 * GitHub polling may return no issues, but the dashboard UI and connections are
 * fully exercised.
 */
export default defineConfig({
  testDir: "./tests/e2e",
  fullyParallel: false,
  retries: 0,
  workers: 1,
  reporter: "list",

  use: {
    baseURL: "http://localhost:4001",
    trace: "on-first-retry",
  },

  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],

  webServer: {
    command:
      "mise exec -- ./bin/symphony --i-understand-that-this-will-be-running-without-the-usual-guardrails --port 4001 ./WORKFLOW.md",
    url: "http://localhost:4001",
    timeout: 60_000,
    reuseExistingServer: !process.env.CI,
    stdout: "pipe",
    stderr: "pipe",
    env: {
      SYMPHONY_GITHUB_TOKEN: process.env.SYMPHONY_GITHUB_TOKEN ?? "",
    },
  },
});
