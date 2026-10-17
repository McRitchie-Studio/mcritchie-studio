// [e2e] /build — the app funnel, the way a new visitor walks it: a chat with Xan
// (BuildIntake; .agents/epics/build-with-xan-design.md).
//
// The promise only a browser can prove: a SIGNED-OUT visitor talks to Xan, taps
// the intake cards Xan sends (CTO, colors, address), watches the checklist fill
// and Build my app light up, and only THEN signs in; the emailed link returns to
// the same chat, and Build queues the app. The spec plays the dispatcher through
// the real mailbox API (claim, complete with an intake card), and the page,
// which has no /cable socket signed out, picks each answer up by polling. Mobile
// width and both themes are measured on the way.
//
// NOT @qa-readonly: it writes requests and agent messages. Nothing here talks to Claude.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");
const { CONTRAST, eachTheme, TEXT_ON_SURFACE } = require("./contrast");

// What a visitor sees: signed out, not the suite's default admin session.
test.use({ storageState: VISITOR });

const PALETTE = {
  name: "Pitch",
  light: { primary: "#15803d", accent: "#f59e0b", surface: "#ffffff", text: "#111827" },
  dark: { primary: "#4ade80", accent: "#fbbf24", surface: "#0b1220", text: "#f1f5f9" },
};

// The mailbox API's bearer token, read from an admin page in a SEPARATE context,
// so the visitor's own browser stays signed out.
async function adminToken(browser) {
  const context = await browser.newContext();
  const admin = await context.newPage();
  await loginWithMagicLink(admin, "alex@test.com");
  await admin.goto("/agents/activities");
  const token = await admin.getAttribute("meta[name='e2e-api-token']", "content");
  await context.close();
  return token;
}

// Xan's answer to the visitor's newest message, as bin/dispatcher sends it. A
// leftover xan row from another spec is answered and passed over.
async function xanAnswers(page, auth, content, text, card) {
  const worker = `e2e-build-${Date.now()}`;
  for (let i = 0; i < 10; i += 1) {
    const claimed = await page.request.post("/api/v1/agent_messages/claim", { headers: auth, data: { souls: ["xan"], worker, channel: "web" } });
    expect(claimed.ok()).toBeTruthy();
    const message = (await claimed.json()).data;
    expect(message, `a xan message waiting for "${content}"`).toBeTruthy();
    const mine = message.content === content;
    const body = mine && card ? `${text}\n===PROPOSAL===\n${JSON.stringify({ kind: "intake", ...card })}` : (mine ? text : "ok");
    const done = await page.request.post(`/api/v1/agent_messages/${message.id}/complete`, { headers: auth, data: { worker, response_text: body } });
    expect(done.ok()).toBeTruthy();
    if (mine) return;
  }
  throw new Error(`never claimed "${content}"`);
}

async function say(page, text) {
  const input = page.locator("[data-test='cto-chat-input']");
  await input.fill(text);
  await input.press("Enter");
  await expect(page.locator("[data-test='build-turn']", { hasText: text })).toHaveCount(1);
}

test("a signed-out visitor completes the intake cards, sees Build my app light up, then signs in and it is queued", async ({ page, browser }) => {
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  const auth = { Authorization: `Bearer ${await adminToken(browser)}`, "Content-Type": "application/json" };
  const email = `new-builder-${Date.now()}@example.test`;
  const idea = `A league site with schedules, scores and standings ${Date.now()}`;
  const address = `league-${Date.now().toString(36)}`;

  await page.goto("/build");
  const box = page.getByLabel("Tell Xan what you want to build");
  await box.fill(idea);
  // A person takes longer than the bot shield's two seconds to type an idea.
  await page.waitForTimeout(2200);
  await box.press("Enter");

  // Straight into the chat, still signed out: no sign-in before Build.
  await page.waitForURL((u) => /^\/build\/[A-Za-z0-9_-]{10,}$/.test(u.pathname));
  await expect(page.locator("[data-test='auth-modal']")).toBeHidden();
  await expect(page.getByRole("heading", { name: "Build with Xan" })).toBeVisible();
  const first = page.locator("[data-test='build-turn']", { hasText: idea });
  await expect(first).toHaveAttribute("data-pending", "true");
  await expect(page.locator("[data-test='build-my-app']")).toBeDisabled();

  // Xan answers; the poll brings the reply and its card in without a reload.
  await xanAnswers(page, auth, idea, "Here's your idea, sharpened.", { card: "idea", idea: "A league site with live standings", audience: "rec league players" });
  await expect(first.locator("[data-test='cto-chat-reply']")).toContainText("sharpened");
  await first.locator("[data-test='build-choose-idea']").click();
  await expect(page.locator("[data-test='build-check-idea']")).toHaveAttribute("data-done", "true");

  await say(page, "Yes, that's it");
  await xanAnswers(page, auth, "Yes, that's it", "Who should run it?", { card: "cto", names: ["Coach", "Ref", "Scout"], portrait: "harbor" });
  const cto = page.locator("[data-test='build-card-cto']");
  await expect(cto.locator("[data-test='build-portraits'] img")).toHaveCount(12);
  await cto.getByText("Ref", { exact: true }).click();
  await cto.locator("label[title='Meadow']").click();
  await cto.locator("[data-test='build-choose-cto']").click();
  await expect(page.locator("[data-test='build-check-cto-value']")).toHaveText("Ref");

  await say(page, "Colors next");
  await xanAnswers(page, auth, "Colors next", "Pick a palette.", { card: "palette", palettes: [PALETTE] });
  const palette = page.locator("[data-test='build-palette']").first();
  await expect(palette.locator("[data-test='build-palette-preview'] [data-mode='dark']")).toHaveCSS("background-color", "rgb(11, 18, 32)");
  await palette.locator("[data-test='build-choose-palette']").click();
  await expect(page.locator("[data-test='build-check-colors-value']")).toHaveText("Pitch");

  await say(page, "And the address");
  await xanAnswers(page, auth, "And the address", "Pick an address.", { card: "address", names: [address] });
  const card = page.locator("[data-test='build-card-address']");
  await card.locator("[data-test='build-address-input']").fill("www");
  await expect(card.locator("[data-test='build-address-availability']")).toContainText("reserved");
  await expect(card.locator("[data-test='build-choose-address']")).toBeDisabled();
  await card.locator("[data-test='build-address-suggestion']").click();
  await expect(card.locator("[data-test='build-address-availability']")).toContainText("Available");
  await card.locator("[data-test='build-choose-address']").click();

  // All four set: Build my app lights up, and only now asks for sign-in.
  const build = page.locator("[data-test='build-my-app']");
  await expect(page.locator("[data-test='build-checklist']")).toHaveAttribute("data-complete", "true");
  await expect(build).toBeEnabled();

  // Both themes: the chat and the checklist read. A phone: nothing runs off the side.
  await eachTheme(page, async (theme) => {
    for (const selector of ["[data-test='cto-chat-sent']", "[data-test='cto-chat-reply'] p", "[data-test='build-checklist'] .text-heading"]) {
      const measured = await page.evaluate(CONTRAST, selector);
      expect(measured.length, `${theme}: ${selector} renders`).toBeGreaterThan(0);
      for (const m of measured) expect(m.ratio, `${theme}: ${selector} "${m.text}"`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    }
  });
  await page.setViewportSize({ width: 360, height: 780 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "nothing runs off the side at 360px").toBeLessThanOrEqual(0);
  await page.setViewportSize({ width: 1280, height: 800 });

  await build.click();
  const modal = page.locator("[data-test='auth-modal']");
  await expect(modal).toBeVisible();
  await modal.locator("#auth-email").fill(email);
  await Promise.all([
    page.waitForResponse((r) => r.url().includes("/magic_link") && r.request().method() === "POST" && r.ok()),
    modal.getByRole("button", { name: "Email me a sign-in link" }).click(),
  ]);

  let link;
  for (let attempt = 0; attempt < 10 && !link; attempt += 1) {
    const inbox = await page.request.get("/_studio/local_emails.json").then((r) => r.json());
    link = inbox.deliveries.find((d) => d.to === email && d.action_url);
    if (!link) await page.waitForTimeout(200);
  }
  expect(link, "the sign-in email was sent").toBeTruthy();

  // The link returns to the SAME chat, now signed in, and the checklist held.
  const chatPath = new URL(page.url()).pathname;
  await page.goto(new URL(link.action_url, page.url()).pathname);
  if (new URL(page.url()).pathname !== chatPath) {
    await page.locator("#magic-consume-form").evaluate((form) => form.requestSubmit());
  }
  await page.waitForURL((u) => u.pathname === chatPath);
  const onboarding = page.getByRole("dialog", { name: "onboarding first name" });
  await expect(onboarding).toBeVisible();
  await onboarding.getByLabel("First name").fill("Jordan");
  await onboarding.getByRole("button", { name: "Save and continue" }).click();
  await expect(onboarding).toBeHidden();
  await expect(page.locator("[data-test='build-turn']", { hasText: idea })).toHaveCount(1);

  await page.getByRole("button", { name: "Build my app" }).click();
  await expect(page.locator("[data-test='build-request']")).toHaveAttribute("data-status", "queued");
  await expect(page.locator("[data-test='build-host']")).toHaveText(`${address}.mcritchie.studio`);
  expect(pageErrors, report()).toHaveLength(0);
});

test("on a phone an admin names a showcase app: full-width field, pasted address cleaned, queued", async ({ page }) => {
  await page.setViewportSize({ width: 360, height: 780 });
  await loginWithMagicLink(page, "alex@test.com");
  const onboarding = page.getByRole("dialog", { name: "onboarding first name" });

  // Two apps from one admin account: the second must queue too (showcase exemption).
  // Unregistered names: the real showcase apps (prisoners-dilemma, weekly-lock, ...)
  // have config/satellites.yml rows, so their subdomains are reserved.
  for (const name of ["coin-toss", "chess-club"]) {
    await page.goto("/build");
    if (await onboarding.isVisible().catch(() => false)) {
      await onboarding.getByRole("button", { name: "Skip for now" }).click();
      await expect(onboarding).toBeHidden();
    }
    await page.getByLabel("Tell Xan what you want to build").fill(`Rebuild of my old ${name} app`);
    await page.getByLabel("Tell Xan what you want to build").press("Enter");
    await page.waitForURL((u) => /^\/build\/[A-Za-z0-9_-]{10,}$/.test(u.pathname));
    // An admin skips the checklist through the name step under the chat.
    await page.locator("[data-test='build-admin-claim'] summary").click();

    const field = page.locator("[data-test='build-subdomain']");
    const width = await field.evaluate((el) => el.getBoundingClientRect().width);
    expect(width, "the name keeps the room at 360px").toBeGreaterThan(180);

    await field.fill(`https://${name}.mcritchie.studio/`);
    await expect(field).toHaveValue(name);
    await expect(page.locator("[data-test='build-address-preview']")).toHaveText(`${name}.mcritchie.studio`);
    await page.locator("[data-test='build-claim-submit']").click();
    await expect(page.locator("[data-test='build-request']")).toHaveAttribute("data-status", "queued");
  }

  // Both of THIS spec's apps are listed as showcase. (Not a total count: the
  // seed carries live showcase apps of its own for the gallery spec.)
  await page.goto("/build/requests?status=showcase");
  for (const name of ["coin-toss", "chess-club"]) {
    const row = page.locator("[data-test='app-request']", { has: page.locator("[data-test='app-request-host']", { hasText: `${name}.mcritchie.studio` }) });
    await expect(row.locator("[data-test='app-request-showcase']")).toHaveCount(1);
  }
});
