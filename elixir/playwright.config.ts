import { defineConfig, devices } from "@playwright/test";

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
