// [e2e] /build — the app funnel, the way a new visitor walks it.
//
// The promise only a browser can prove: a prompt typed while SIGNED OUT survives
// the sign-in detour. Enter opens the standard sign-in modal over the composer,
// the emailed link lands in the local inbox, and following it returns to the
// SAME draft — then they claim a name and see the build queued.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, loginWithMagicLink } = require("./helpers");

test("a signed-out visitor's prompt survives sign-in, then they claim a name and see it queued", async ({ page }) => {
  await blockThirdPartyRequests(page);
  const email = "new-builder@example.test";
  const prompt = "A league site with schedules, scores and standings";

  await page.goto("/build");
  const box = page.getByLabel("Describe your app");
  await box.fill(prompt);
  await box.press("Enter");

  // Signed out, the visitor stays on /build and the standard sign-in modal opens.
  const modal = page.locator("[data-test='auth-modal']");
  await expect(modal).toBeVisible();
  await expect(modal.getByRole("heading")).toHaveText("Create your free account");
  expect(new URL(page.url()).pathname).toBe("/build");

  await modal.locator("#auth-email").fill(email);
  await Promise.all([
    page.waitForResponse((r) => r.url().includes("/magic_link") && r.request().method() === "POST" && r.ok()),
    modal.getByRole("button", { name: "Email me a sign-in link" }).click(),
  ]);
  await expect(page.getByText("Check your inbox")).toBeVisible();

  let link;
  for (let attempt = 0; attempt < 10 && !link; attempt += 1) {
    const inbox = await page.request.get("/_studio/local_emails.json").then((r) => r.json());
    link = inbox.deliveries.find((d) => d.to === email && d.action_url);
    if (!link) await page.waitForTimeout(200);
  }
  expect(link, "the sign-in email was sent").toBeTruthy();

  // Following the link lands on the saved draft — the prompt survived.
  await page.goto(new URL(link.action_url, page.url()).pathname);
  const isDraft = (u) => /^\/build\/[A-Za-z0-9_-]{10,}$/.test(u.pathname);
  if (!isDraft(new URL(page.url()))) {
    await page.locator("#magic-consume-form").evaluate((form) => form.requestSubmit());
  }
  await page.waitForURL(isDraft);

  // Back on the same draft, now signed in. A brand-new account is first asked
  // its first name (the site-wide onboarding dialog) — answer it like a person.
  await expect(page.locator("[data-test='build-echo']")).toHaveText(prompt);
  const onboarding = page.getByRole("dialog", { name: "onboarding first name" });
  await expect(onboarding).toBeVisible();
  await onboarding.getByLabel("First name").fill("Jordan");
  await onboarding.getByRole("button", { name: "Save and continue" }).click();
  await expect(onboarding).toBeHidden();

  // Name the app. The field is focused as soon as the dialog closes, and is
  // already typing example names into its placeholder.
  const name = page.locator("[data-test='build-subdomain']");
  await expect(name).toBeFocused();
  await expect(name).toHaveAttribute("placeholder", /[a-z]/);

  // Whatever is typed is cleaned into a valid name as it goes.
  await name.pressSequentially("League Hub!");
  await expect(name).toHaveValue("league-hub-");
  await name.fill("");

  await name.fill("www");
  await expect(page.locator("[data-test='build-availability']")).toContainText("reserved");
  await name.fill("league-hub");
  await expect(page.locator("[data-test='build-availability']")).toContainText("Available");
  await page.getByRole("button", { name: "Build my app" }).click();

  await expect(page.locator("[data-test='build-request']")).toHaveAttribute("data-status", "queued");
  await expect(page.locator("[data-test='build-host']")).toHaveText("league-hub.mcritchie.studio");
});

test("on a phone an admin names a showcase app: full-width field, pasted address cleaned, queued", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 780 });
  await loginWithMagicLink(page, "alex@test.com");
  const onboarding = page.getByRole("dialog", { name: "onboarding first name" });

  // Two apps from one admin account: the second must queue too (showcase exemption).
  // Unregistered names: the real showcase apps (prisoners-dilemma, weekly-lock, ...)
  // have config/satellites.yml rows, so their subdomains are reserved.
  for (const name of ["coin-toss", "trivia-night"]) {
    await page.goto("/build");
    if (await onboarding.isVisible().catch(() => false)) {
      await onboarding.getByRole("button", { name: "Skip for now" }).click();
      await expect(onboarding).toBeHidden();
    }
    await page.getByLabel("Describe your app").fill(`Rebuild of my old ${name} app`);
    await page.getByLabel("Describe your app").press("Enter");
    await page.waitForURL((u) => /^\/build\/[A-Za-z0-9_-]{10,}$/.test(u.pathname));

    const field = page.locator("[data-test='build-subdomain']");
    const width = await field.evaluate((el) => el.getBoundingClientRect().width);
    expect(width, "the name keeps the room at 360px").toBeGreaterThan(180);

    await field.fill(`https://${name}.mcritchie.studio/`);
    await expect(field).toHaveValue(name);
    await expect(page.locator("[data-test='build-address-preview']")).toHaveText(`${name}.mcritchie.studio`);
    await page.getByRole("button", { name: "Build my app" }).click();
    await expect(page.locator("[data-test='build-request']")).toHaveAttribute("data-status", "queued");
  }

  await page.goto("/build/requests?status=showcase");
  await expect(page.locator("[data-test='app-request-showcase']")).toHaveCount(2);
});
