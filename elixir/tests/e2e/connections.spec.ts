import { test, expect } from "@playwright/test";
import { execSync } from "child_process";

test.describe("Connection checks", () => {
  test("Claude Code CLI is available and responding", async () => {
    let output: string;
    try {
      output = execSync("claude --version", { encoding: "utf8", timeout: 10_000 }).trim();
    } catch {
      throw new Error("claude CLI not found or failed to run. Is Claude Code installed?");
    }
    expect(output.length).toBeGreaterThan(0);
    console.log(`Claude Code version: ${output}`);
  });

  test("GitHub API is reachable with configured token", async ({ request }) => {
    const token = process.env.SYMPHONY_GITHUB_TOKEN;
    expect(token, "SYMPHONY_GITHUB_TOKEN is not set").toBeTruthy();

    const response = await request.get("https://api.github.com/user", {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    });

    expect(response.status(), "GitHub API auth failed — check SYMPHONY_GITHUB_TOKEN").toBe(200);

    const body = await response.json();
    console.log(`GitHub authenticated as: ${body.login}`);
  });

  test("GitHub repo is accessible", async ({ request }) => {
    const token = process.env.SYMPHONY_GITHUB_TOKEN;
    const repo = "phase2interactive/symphony";

    const response = await request.get(`https://api.github.com/repos/${repo}`, {
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    });

    expect(
      response.status(),
      `Could not access repo ${repo} — check token has 'repo' scope and the repo exists`
    ).toBe(200);

    const body = await response.json();
    console.log(`Repo accessible: ${body.full_name}`);
  });

  test("Symphony app responds and reports state", async ({ request }) => {
    const response = await request.get("/api/v1/state");
    expect(response.status()).toBe(200);

    const body = await response.json();
    expect(body).toHaveProperty("running");
    console.log(`Symphony state: running=${body.running}, retrying=${body.retrying}`);
  });
});
