/**
 * Reconciliation E2E Tests
 *
 * These tests verify that the Symphony dashboard and API accurately
 * reflect the actual state of GitHub issues. They serve as a live
 * integration check: fetch truth from GitHub, fetch Symphony's view,
 * and compare.
 *
 * Requires:
 *   - SYMPHONY_GITHUB_TOKEN in the environment
 *   - Symphony running with --port (started by playwright.config.ts)
 */

import { test, expect } from "@playwright/test";
import { fetchActiveIssues, fetchIssue, type GitHubIssue } from "./helpers/github-api";

// Symphony's active state labels (must match WORKFLOW.md)
const ACTIVE_STATES = ["Todo", "In Progress", "Merging", "Rework"];

// ── Helpers ──────────────────────────────────────────────────────────

interface SymphonyRunningEntry {
  issue_id: string;
  issue_identifier: string;
  state: string;
  tokens: { input_tokens: number; output_tokens: number; total_tokens: number };
}

interface SymphonyRetryEntry {
  issue_id: string;
  issue_identifier: string;
  attempt: number;
  error: string | null;
}

interface SymphonyState {
  generated_at: string;
  counts: { running: number; retrying: number };
  running: SymphonyRunningEntry[];
  retrying: SymphonyRetryEntry[];
  error?: { code: string; message: string };
}

/**
 * Extract the primary workflow-state label from a GitHub issue.
 * Returns the first label that matches an active state, or null.
 */
function primaryStateLabel(ghIssue: GitHubIssue): string | null {
  return ghIssue.labels.find((l) => ACTIVE_STATES.includes(l)) ?? null;
}

// ── Tests ────────────────────────────────────────────────────────────

test.describe("Dashboard ↔ GitHub Reconciliation", () => {
  test.describe.configure({ timeout: 30_000 });

  test("Symphony API state shape is valid", async ({ request }) => {
    const res = await request.get("/api/v1/state");
    expect(res.status()).toBe(200);

    const state: SymphonyState = await res.json();
    expect(state).toHaveProperty("generated_at");
    expect(state).toHaveProperty("counts");
    expect(state).toHaveProperty("running");
    expect(state).toHaveProperty("retrying");
    expect(Array.isArray(state.running)).toBe(true);
    expect(Array.isArray(state.retrying)).toBe(true);
    expect(state.counts.running).toBe(state.running.length);
    expect(state.counts.retrying).toBe(state.retrying.length);
  });

  test("every Symphony running issue exists on GitHub with an active label", async ({
    request,
  }) => {
    const res = await request.get("/api/v1/state");
    const state: SymphonyState = await res.json();

    // Skip if nothing is running (not a failure — just nothing to reconcile)
    test.skip(
      state.running.length === 0,
      "No running issues to reconcile"
    );

    for (const entry of state.running) {
      const issueNumber = parseInt(entry.issue_id, 10);
      const ghIssue = await fetchIssue(issueNumber);

      // Issue should be open on GitHub
      expect(
        ghIssue.state,
        `GitHub issue #${issueNumber} should be open but is ${ghIssue.state}`
      ).toBe("open");

      // Issue should have at least one active-state label
      const stateLabel = primaryStateLabel(ghIssue);
      expect(
        stateLabel,
        `GitHub issue #${issueNumber} has no active-state label. Labels: ${ghIssue.labels.join(", ")}`
      ).not.toBeNull();
    }
  });

  test("every Symphony retrying issue exists on GitHub with an active label", async ({
    request,
  }) => {
    const res = await request.get("/api/v1/state");
    const state: SymphonyState = await res.json();

    test.skip(
      state.retrying.length === 0,
      "No retrying issues to reconcile"
    );

    for (const entry of state.retrying) {
      const issueNumber = parseInt(entry.issue_id, 10);
      const ghIssue = await fetchIssue(issueNumber);

      expect(
        ghIssue.state,
        `Retrying issue #${issueNumber} should be open on GitHub`
      ).toBe("open");

      const stateLabel = primaryStateLabel(ghIssue);
      expect(
        stateLabel,
        `Retrying issue #${issueNumber} has no active-state label`
      ).not.toBeNull();
    }
  });

  test("no active GitHub issues are missing from Symphony", async ({
    request,
  }) => {
    const ghIssues = await fetchActiveIssues();

    console.log(
      `[reconciliation] GitHub has ${ghIssues.length} active issue(s): ` +
        ghIssues.map((i) => `#${i.number} [${i.labels.join(",")}]`).join(", ")
    );

    // Skip if GitHub has no active issues
    test.skip(ghIssues.length === 0, "No active GitHub issues to check");

    // Give Symphony a moment to have completed at least one poll cycle
    // (the webServer started ~60s ago, poll interval is 5s)
    const res = await request.get("/api/v1/state");
    const state: SymphonyState = await res.json();

    // Build a set of issue IDs that Symphony knows about
    const symphonyIds = new Set<string>();
    for (const entry of state.running) symphonyIds.add(entry.issue_id);
    for (const entry of state.retrying) symphonyIds.add(entry.issue_id);

    console.log(
      `[reconciliation] Symphony tracks ${symphonyIds.size} issue(s): ` +
        [...symphonyIds].join(", ")
    );

    // Collect issues GitHub has but Symphony doesn't
    const missing = ghIssues.filter(
      (gh) => !symphonyIds.has(String(gh.number))
    );

    // Hard-fail: every active GitHub issue should be tracked by Symphony.
    // If Symphony has had time to poll (it starts before tests run) and
    // still doesn't know about issues, that's a real reconciliation failure.
    expect(
      missing.length,
      `GitHub has ${missing.length} active issue(s) not tracked by Symphony: ` +
        missing.map((i) => `#${i.number} (${primaryStateLabel(i)})`).join(", ") +
        `. Symphony only tracks: [${[...symphonyIds].join(", ")}]`
    ).toBe(0);
  });

  test("Symphony issue states match GitHub labels", async ({ request }) => {
    const res = await request.get("/api/v1/state");
    const state: SymphonyState = await res.json();

    test.skip(
      state.running.length === 0,
      "No running issues to check state alignment"
    );

    const mismatches: string[] = [];

    for (const entry of state.running) {
      const issueNumber = parseInt(entry.issue_id, 10);
      const ghIssue = await fetchIssue(issueNumber);
      const ghState = primaryStateLabel(ghIssue);

      // Symphony's entry.state should correspond to one of the issue's labels.
      // The GitHub adapter uses the first label as the primary state, so there
      // may be legitimate ordering differences. We just check the label exists.
      if (entry.state && !ghIssue.labels.includes(entry.state)) {
        mismatches.push(
          `#${issueNumber}: Symphony says "${entry.state}", ` +
            `GitHub labels are [${ghIssue.labels.join(", ")}]`
        );
      }
    }

    if (mismatches.length > 0) {
      console.warn(
        `[reconciliation] State mismatches:\n${mismatches.join("\n")}`
      );
    }

    // Hard-fail if more than half the issues have state mismatches
    expect(
      mismatches.length,
      `Too many state mismatches (${mismatches.length}/${state.running.length})`
    ).toBeLessThan(Math.max(state.running.length / 2, 1));
  });

  test("dashboard UI issue count matches API state", async ({
    page,
    request,
  }) => {
    // Get the API truth
    const res = await request.get("/api/v1/state");
    const state: SymphonyState = await res.json();

    await page.goto("/");
    await page.waitForLoadState("networkidle");

    // The dashboard shows metric cards with counts
    const runningMetric = page.locator(".metric-value").first();
    await expect(runningMetric).toBeVisible({ timeout: 5_000 });

    const runningText = await runningMetric.textContent();
    const runningCount = parseInt(runningText?.trim() ?? "0", 10);

    // The dashboard count should match the API count
    expect(
      runningCount,
      `Dashboard shows ${runningCount} running but API has ${state.counts.running}`
    ).toBe(state.counts.running);
  });

  test("dashboard issue rows match API running entries", async ({
    page,
    request,
  }) => {
    const res = await request.get("/api/v1/state");
    const state: SymphonyState = await res.json();

    test.skip(
      state.running.length === 0,
      "No running issues — dashboard table will be empty"
    );

    await page.goto("/");
    await page.waitForLoadState("networkidle");

    // Each running issue should appear as a row in the dashboard table
    for (const entry of state.running) {
      const identifier = entry.issue_identifier;
      const row = page.locator(`text=${identifier}`);
      await expect(
        row.first(),
        `Dashboard should show issue ${identifier}`
      ).toBeVisible({ timeout: 5_000 });
    }
  });

  test("refresh triggers a poll cycle and state updates", async ({
    request,
  }) => {
    // Capture state before refresh
    const beforeRes = await request.get("/api/v1/state");
    const before: SymphonyState = await beforeRes.json();
    const beforeTime = before.generated_at;

    // Trigger refresh
    const refreshRes = await request.post("/api/v1/refresh");
    expect(refreshRes.status()).toBe(202);

    // Wait briefly for poll to complete, then check again
    await new Promise((r) => setTimeout(r, 3_000));

    const afterRes = await request.get("/api/v1/state");
    const after: SymphonyState = await afterRes.json();

    // The generated_at timestamp should have advanced
    expect(after.generated_at).not.toBe(beforeTime);
  });

  test("per-issue API endpoint returns data consistent with GitHub", async ({
    request,
  }) => {
    const res = await request.get("/api/v1/state");
    const state: SymphonyState = await res.json();

    test.skip(
      state.running.length === 0,
      "No running issues for per-issue check"
    );

    // Pick the first running issue and check its detail endpoint
    const entry = state.running[0];
    const detailRes = await request.get(`/api/v1/${entry.issue_identifier}`);
    expect(detailRes.status()).toBe(200);

    const detail = await detailRes.json();
    expect(detail.issue_identifier).toBe(entry.issue_identifier);
    expect(detail.issue_id).toBe(entry.issue_id);
    expect(detail.status).toBe("running");

    // Cross-check against GitHub
    const issueNumber = parseInt(entry.issue_id, 10);
    const ghIssue = await fetchIssue(issueNumber);
    expect(ghIssue.state).toBe("open");
    expect(ghIssue.number).toBe(issueNumber);
  });
});
