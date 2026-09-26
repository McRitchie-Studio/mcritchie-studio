// [e2e] /build — the app funnel, the way a new visitor walks it.
//
// The promise only a browser can prove: a prompt typed while SIGNED OUT survives
// the sign-in detour. The visitor uses the /build page's own email form, the
// link lands in the local inbox, and following it returns to the SAME draft —
// then they claim a name and see the build queued.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests } = require("./helpers");

test("a signed-out visitor's prompt survives sign-in, then they claim a name and see it queued", async ({ page }) => {
  await blockThirdPartyRequests(page);
  const email = "new-builder@example.test";
  const prompt = "A league site with schedules, scores and standings";

  await page.goto("/build");
  const box = page.getByLabel("Describe your app");
  await box.fill(prompt);
  await box.press("Enter");

  await page.waitForURL(/\/build\/[A-Za-z0-9_-]{10,}$/);
  const draftPath = new URL(page.url()).pathname;
  await expect(page.locator("[data-test='build-echo']")).toHaveText(prompt);

  // Register with the /build page's own email form.
  await page.locator("#build-email").fill(email);
  await Promise.all([
    page.waitForResponse((r) => r.url().includes("/magic_link") && r.request().method() === "POST" && r.ok()),
    page.getByRole("button", { name: "Email me a sign-in link" }).click(),
  ]);

  let link;
  for (let attempt = 0; attempt < 10 && !link; attempt += 1) {
    const inbox = await page.request.get("/_studio/local_emails.json").then((r) => r.json());
    link = inbox.deliveries.find((d) => d.to === email && d.action_url);
    if (!link) await page.waitForTimeout(200);
  }
  expect(link, "the sign-in email was sent").toBeTruthy();

  await page.goto(new URL(link.action_url, page.url()).pathname);
  if (new URL(page.url()).pathname !== draftPath) {
    await page.locator("#magic-consume-form").evaluate((form) => form.requestSubmit());
  }
  await page.waitForURL((u) => u.pathname === draftPath);

  // Back on the same draft, now signed in. A brand-new account is first asked
  // its first name (the site-wide onboarding dialog) — answer it like a person.
  await expect(page.locator("[data-test='build-echo']")).toHaveText(prompt);
  const onboarding = page.getByRole("dialog", { name: "onboarding first name" });
  await expect(onboarding).toBeVisible();
  await onboarding.getByLabel("First name").fill("Jordan");
  await onboarding.getByRole("button", { name: "Save and continue" }).click();
  await expect(onboarding).toBeHidden();

  // Name the app.
  const name = page.locator("[data-test='build-subdomain']");
  await name.fill("www");
  await expect(page.locator("[data-test='build-availability']")).toContainText("reserved");
  await name.fill("league-hub");
  await expect(page.locator("[data-test='build-availability']")).toContainText("Available");
  await page.getByRole("button", { name: "Build my app" }).click();

  await expect(page.locator("[data-test='build-request']")).toHaveAttribute("data-status", "queued");
  await expect(page.locator("[data-test='build-host']")).toHaveText("league-hub.mcritchie.studio");
});
