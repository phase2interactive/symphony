import { test, expect } from "@playwright/test";

test.describe("Symphony Observability Dashboard", () => {
  test("dashboard page loads with expected title and structure", async ({
    page,
  }) => {
    await page.goto("/");

    await expect(page).toHaveTitle(/Symphony/);
    await expect(
      page.getByRole("heading", { name: "Operations Dashboard" })
    ).toBeVisible();
    await expect(page.getByText("Symphony Observability")).toBeVisible();
  });

  test("metric cards are visible", async ({ page }) => {
    await page.goto("/");

    // Core metric cards should render (use exact match on the metric-label paragraphs)
    await expect(
      page.locator(".metric-label", { hasText: "Running" }).first()
    ).toBeVisible();
    await expect(
      page.locator(".metric-label", { hasText: "Retrying" })
    ).toBeVisible();
    await expect(
      page.locator(".metric-label", { hasText: "Total tokens" })
    ).toBeVisible();
    await expect(
      page.locator(".metric-label", { hasText: "Runtime" })
    ).toBeVisible();
  });

  test("API state endpoint returns JSON", async ({ request }) => {
    const response = await request.get("/api/v1/state");

    expect(response.status()).toBe(200);
    expect(response.headers()["content-type"]).toContain("application/json");

    const body = await response.json();
    expect(body).toHaveProperty("running");
    expect(body).toHaveProperty("retrying");
  });

  test("LiveView WebSocket connection is established", async ({ page }) => {
    const liveViewConnected = page.waitForEvent("websocket", {
      predicate: (ws) => ws.url().includes("/live/websocket"),
      timeout: 5_000,
    });

    await page.goto("/");
    await liveViewConnected;
  });
});
