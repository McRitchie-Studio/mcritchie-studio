// [e2e] /build — the app funnel, the way a new visitor walks it: a chat with the
// intake agent (BuildIntake; .agents/epics/build-with-xan-design.md, and v2's cards
// that move the chat on, .agents/epics/build-with-ray-v2.md).
//
// The promise only a browser can prove: a SIGNED-OUT visitor types ONE message, which
// answers IN PLACE on /build (the thread grows under the heading and the address
// becomes /build/<token>, no reload), then gets from the idea to Build My App by TAPS
// ALONE. The status card waits for Start App, then its Theme · Agent · Domain tiles
// fill in the order Ray asks (theme before CTO). Every card's CTA sets its field and
// posts the visitor's own line into the thread, so the next answer arrives without
// typing: Start App on the idea, Choose Theme (the middle theme preselected, another
// picked after the dark/light toggle), Hatch CTO (a portrait picked in the modal,
// the prefilled name edited), and Use Domain (a chip picked, the name edited and
// typed back while the chip's glow follows the field). The summary card follows, and Build My App asks for sign-in only
// then; the emailed link returns to the same chat, and Build My App launches the app
// and moves the page to the new CTO's chat (a Turbo visit, no reload), where the
// CTO's code-written greeting is already there. The
// spec plays the dispatcher through the real mailbox API (claim, complete with an
// intake card), and the page, which has no /cable socket signed out, picks each
// answer up by polling. Mobile width and both themes are measured on the way.
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

// Ray's answer (soul slug ray) to the visitor's newest message, as bin/dispatcher
// sends it. A leftover ray row from another spec is answered and passed over.
// With `phases`, it first pulses thinking, then typing, and the pending turn's
// poll shows each in turn (the dispatcher reads them off Claude's stream).
async function rayAnswers(page, auth, content, text, card, { phases = false } = {}) {
  const worker = `e2e-build-${Date.now()}`;
  for (let i = 0; i < 10; i += 1) {
    const claimed = await page.request.post("/api/v1/agent_messages/claim", { headers: auth, data: { souls: ["ray"], worker, channel: "web" } });
    expect(claimed.ok()).toBeTruthy();
    const message = (await claimed.json()).data;
    expect(message, `a ray message waiting for "${content}"`).toBeTruthy();
    const mine = message.content === content;
    if (mine && phases) {
      const indicator = page.locator("[data-test='build-turn']", { hasText: content }).locator("[data-test='cto-chat-typing']");
      for (const phase of ["thinking", "typing"]) {
        const pulse = await page.request.post(`/api/v1/agent_messages/${message.id}/typing`, { headers: auth, data: { worker, phase } });
        expect((await pulse.json()).meta.typing).toBe("queued");
        await expect(indicator).toHaveAttribute("data-phase", phase);
      }
      await expect(indicator.locator("[data-test='cto-chat-typing-bubble']")).toBeVisible();
      await expect(indicator.locator("[data-test='cto-chat-typing-bubble']")).toContainText("Ray is typing");
      await expect(indicator.locator("[data-test='cto-chat-thinking']")).toBeHidden();
    }
    const body = mine && card ? `${text}\n===PROPOSAL===\n${JSON.stringify({ kind: "intake", ...card })}` : (mine ? text : "ok");
    const done = await page.request.post(`/api/v1/agent_messages/${message.id}/complete`, { headers: auth, data: { worker, response_text: body } });
    expect(done.ok()).toBeTruthy();
    if (mine) return;
  }
  throw new Error(`never claimed "${content}"`);
}

// The visitor's line a tap posted, and the agent's answer to it.
async function tapped(page, auth, line, text, card) {
  await expect(page.locator("[data-test='build-turn']", { hasText: line }), `the tap posted "${line}"`).toHaveCount(1);
  await rayAnswers(page, auth, line, text, card);
}

test("a signed-out visitor's first message answers in place, taps alone reach Build My App, and the page becomes the CTO's chat, greeted, with no reload", async ({ page, browser }) => {
  // The whole intake, sign-in and launch in one walk, with the theme, CTO and domain
  // cards each exercised by keyboard and tap: past the suite's 30s default.
  test.setTimeout(90_000);
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  const auth = { Authorization: `Bearer ${await adminToken(browser)}`, "Content-Type": "application/json" };
  const email = `new-builder-${Date.now()}@example.test`;
  const idea = `A league site with schedules, scores and standings ${Date.now()}`;
  const address = `league-${Date.now().toString(36)}`;

  await page.goto("/build");
  // The shell: Ray's portrait on top, the heading, the chat box typing example ideas.
  await expect(page.locator("[data-test='agent-shell'][data-shell='build'] [data-test='agent-chat-header'][data-agent-name='Ray']")).toBeVisible();
  await expect(page.getByRole("heading", { name: "What do you want to build?" })).toBeVisible();
  const box = page.getByLabel("Tell Ray what you want to build");
  // The suite runs under reduced motion (playwright.config.js), where the
  // placeholder holds the first example still; with motion it types.
  const still = await box.getAttribute("placeholder");
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await expect.poll(() => box.getAttribute("placeholder"), { message: "the placeholder types example ideas" }).not.toBe(still);
  await page.emulateMedia({ reducedMotion: "reduce" });
  // A marker on the window: a full page load would wipe it. And a record of the
  // composer's status line, which a screen reader hears while the send posts.
  await page.evaluate(() => {
    window.__buildShellMarker = "kept";
    window.__composerSaid = [];
    new MutationObserver(() => {
      document.querySelectorAll("[data-composer-status]").forEach((s) => { if (s.textContent) window.__composerSaid.push(s.textContent); });
    }).observe(document.body, { subtree: true, childList: true, characterData: true });
  });
  await box.fill(idea);
  // A person takes longer than the bot shield's two seconds to type an idea.
  await page.waitForTimeout(2200);
  await box.press("Enter");

  // The conversation starts HERE, still signed out: the thread grows under the
  // heading, the address moves to /build/<token>, and the page never reloads.
  const first = page.locator("[data-test='build-turn']", { hasText: idea });
  await expect(first).toHaveAttribute("data-pending", "true");
  await expect(page).toHaveURL(/\/build\/[A-Za-z0-9_-]{10,}$/);
  expect(await page.evaluate(() => window.__buildShellMarker), "no reload on the first message").toBe("kept");
  await expect(page.locator("[data-test='auth-modal']")).toBeHidden();
  await expect(page.getByRole("heading", { name: "What do you want to build?" })).toBeVisible();
  await expect(page.locator("[data-test='build-status-card']")).toHaveCount(0);
  await expect(page.locator("[data-test='cto-chat-input']")).toBeFocused();
  expect(await page.evaluate(() => window.__composerSaid), "the send was announced").toContain("Sending…");
  // Once chatting the gallery is gone, as on a reload of /build/<token>.
  await expect(page.locator("[data-test='build-gallery']")).toHaveCount(0);

  // Before Ray is on it the turn is thinking: his portrait in the orbit.
  const waiting = first.locator("[data-test='cto-chat-typing']");
  await expect(waiting).toHaveAttribute("data-phase", "thinking");
  await expect(waiting.locator("[data-test='cto-chat-thinking']")).toContainText("Ray is thinking");
  await expect(waiting.locator("[data-test='cto-chat-thinking'] .agent-typing-orbit")).toBeVisible();

  // The idea card: a title and key features. Start App locks it and moves on.
  await rayAnswers(page, auth, idea, "Here's the app I hear.", { card: "idea", title: "League Standings Hub", features: ["Live standings", "Game schedules"] }, { phases: true });
  const ideaCard = first.locator("[data-test='build-card-idea']");
  await expect(ideaCard.locator("[data-test='build-idea-title']")).toHaveText("League Standings Hub");
  await expect(ideaCard.locator("[data-test='build-idea-features'] li")).toHaveCount(2);
  await expect(ideaCard.locator("[data-test='build-idea-else']")).toBeVisible();
  // The status card waits for Start App: the heading holds until the idea is locked.
  const status = page.locator("[data-test='build-status-card']");
  await expect(status).toHaveCount(0);
  await expect(page.getByRole("heading", { name: "What do you want to build?" })).toBeVisible();
  await ideaCard.getByRole("button", { name: "Start App" }).click();
  await expect(status.locator("[data-test='build-status-title']")).toHaveText("League Standings Hub");
  await expect(page.getByRole("heading", { name: "What do you want to build?" })).toHaveCount(0);
  // The tiles, in the order Ray asks.
  expect(await status.locator("li").evaluateAll((els) => els.map((el) => el.dataset.test))).toEqual(["build-tile-theme", "build-tile-agent", "build-tile-domain"]);

  // The theme comes first: three options, dark first, the middle one preselected; one Choose Theme.
  const themes = ["Pitch", "Field", "Court"].map((name) => ({ ...PALETTE, name }));
  await tapped(page, auth, "Let's build League Standings Hub.", "Pick a theme.", { card: "palette", palettes: themes });
  const themeCard = page.locator("[data-test='build-card-palette']");
  await expect(themeCard.locator("[data-test='build-palette']")).toHaveCount(3);
  await expect(themeCard.getByRole("radio", { name: "Field" })).toBeChecked();
  await expect(themeCard.getByRole("button", { name: "This Theme" })).toHaveCount(0);
  const darkPreview = themeCard.locator("[data-test='build-palette']").first().locator("[data-build-theme-preview='dark']");
  const lightPreview = themeCard.locator("[data-test='build-palette']").first().locator("[data-build-theme-preview='light']");
  await expect(darkPreview).toHaveCSS("background-color", "rgb(11, 18, 32)");
  await expect(lightPreview).toBeHidden();
  await themeCard.locator("[data-test='build-theme-toggle-light']").click();
  await expect(lightPreview).toHaveCSS("background-color", "rgb(255, 255, 255)");
  await expect(darkPreview).toBeHidden();
  await expect(themeCard.locator("[data-test='build-more-like']")).toHaveCount(0);
  // Side by side on a desktop: the three columns share one row.
  const tops = await themeCard.locator("[data-test='build-palette']").evaluateAll((els) => els.map((el) => Math.round(el.getBoundingClientRect().top)));
  expect(new Set(tops).size, "three columns in one row").toBe(1);
  // The keyboard moves the pick like any radio group; a tap on a column picks it.
  await themeCard.getByRole("radio", { name: "Field" }).focus();
  await page.keyboard.press("ArrowRight");
  await expect(themeCard.getByRole("radio", { name: "Court" })).toBeChecked();
  await expect(themeCard.locator("[data-test='build-palette']").nth(2).locator("[data-test='build-palette-check']")).toBeVisible();
  await themeCard.locator("[data-test='build-palette']").nth(0).click();
  await expect(themeCard.getByRole("radio", { name: "Pitch" })).toBeChecked();
  await expect(themeCard.locator("[data-test='build-palette']").nth(2).locator("[data-test='build-palette-check']")).toBeHidden();
  await themeCard.locator("[data-test='build-palette']").nth(1).click();
  await expect(page.locator("[data-test='build-turn']", { hasText: "Let's go with the" }), "picking a theme submits nothing").toHaveCount(0);
  await themeCard.getByRole("button", { name: "Choose Theme" }).click();
  await expect(status.locator("[data-test='build-tile-theme-value']")).toHaveText("Field");
  // The tap re-renders the card (now showing Field as chosen): Light holds.
  await expect(themeCard.locator("[data-test='build-palette']").nth(1)).toHaveAttribute("data-chosen", "true");
  await expect(themeCard.getByRole("radio", { name: "Field" })).toBeChecked();
  await expect(themeCard).toHaveAttribute("data-mode", "light");
  await expect(lightPreview).toBeVisible();
  await expect(themeCard.locator("[data-test='build-theme-toggle-light']")).toHaveAttribute("aria-pressed", "true");

  // What should we call your CTO?: one stack; the name is prefilled; the portrait opens the picker.
  await tapped(page, auth, "Let's go with the Field theme.", "What should we call your CTO?", { card: "cto", names: ["Marble", "Coach", "Scout"], portrait: "harbor" });
  const cto = page.locator("[data-test='build-card-cto']");
  await expect(cto.locator("[data-test='build-cto-heading']")).toHaveText("What should we call your CTO?");
  await expect(cto.locator("[data-test='build-cto-name-input']")).toHaveValue("Marble");
  // Stacked: portrait above the name, the name above its ideas, Hatch CTO at the bottom.
  const ys = await Promise.all(["build-portrait-preview", "build-cto-name-input", "build-cto-names", "build-choose-cto"]
    .map((t) => cto.locator(`[data-test='${t}']`).evaluate((el) => el.getBoundingClientRect().top)));
  expect([...ys].sort((a, b) => a - b), "the CTO card stacks top to bottom").toEqual(ys);
  const dialog = cto.locator("[data-test='build-portrait-dialog']");
  await expect(dialog).toBeHidden();
  await cto.locator("[data-test='build-portrait-new']").click();
  await expect(dialog).toBeVisible();
  await expect(dialog.locator("[data-test='build-portraits'] img")).toHaveCount(12);
  // The keyboard: an arrow moves the pick (and the preview) and the picker stays
  // open for the next one; Enter closes it without submitting the card.
  const preview = cto.locator("[data-test='build-portrait-preview']");
  await dialog.locator("input[name='portrait']:checked").focus();
  const before = await preview.getAttribute("src");
  await page.keyboard.press("ArrowRight");
  await expect(preview).not.toHaveAttribute("src", before);
  await expect(dialog, "an arrow key does not close the picker").toBeVisible();
  await page.keyboard.press("ArrowRight");
  await expect(dialog).toBeVisible();
  await page.keyboard.press("Enter");
  await expect(dialog).toBeHidden();
  await expect(page.locator("[data-test='build-turn']", { hasText: "My CTO is" }), "Enter in the picker submits nothing").toHaveCount(0);
  // A tap on a portrait picks it and closes the picker.
  await cto.locator("[data-test='build-portrait-new']").click();
  await expect(dialog).toBeVisible();
  await dialog.locator("label[title='Meadow']").click();
  await expect(dialog).toBeHidden();
  await expect(cto.locator("[data-test='build-portrait-preview']")).toHaveAttribute("src", /cto_portraits\/meadow/);
  // Every one of Ray's names is a tap, though the first is prefilled.
  await cto.locator("[data-test='build-cto-name-suggestion']", { hasText: "Scout" }).click();
  await expect(cto.locator("[data-test='build-cto-name-input']")).toHaveValue("Scout");
  await expect(cto.locator("[data-test='build-cto-name-suggestion']", { hasText: "Scout" })).toHaveAttribute("aria-pressed", "true");
  await cto.locator("[data-test='build-cto-name-input']").fill("Marbles");
  await cto.getByRole("button", { name: "Hatch CTO" }).click();
  await expect(status.locator("[data-test='build-tile-agent-value']")).toHaveText("Marbles");
  await expect(status.locator("[data-test='build-tile-agent-portrait']")).toHaveAttribute("src", /cto_portraits\/meadow/);

  // The domain: one stack. Bare-name chips (a taken one, the seed's live trivia-night, drawn
  // disabled), the field with the suffix inside it, a glowing Use Domain. The field is the
  // source of truth for the glow. A 30-character suggestion (the longest a name may be) must fit a phone's card.
  const longest = "standings-hub-for-weekend-club";
  await tapped(page, auth, "My CTO is Marbles.", "Pick a domain.", { card: "address", names: ["trivia-night", address, longest] });
  const domainCard = page.locator("[data-test='build-card-address']");
  const field = domainCard.locator("[data-test='build-address-input']");
  const chip = (name) => domainCard.locator("[data-test='build-address-suggestion']", { hasText: name });
  const useDomain = domainCard.getByRole("button", { name: "Use Domain" });
  await page.setViewportSize({ width: 360, height: 780 });
  const fit = await domainCard.evaluate((card) => {
    const edge = card.getBoundingClientRect().right;
    return [...card.querySelectorAll("[data-test='build-address-suggestion'], [data-test='build-address-field']")].map((el) => edge - el.getBoundingClientRect().right);
  });
  expect(Math.min(...fit), "every domain chip and the field end inside the card at 360px").toBeGreaterThanOrEqual(0);
  await expect(domainCard.locator("[data-test='build-address-suffix']")).toBeVisible();
  await page.setViewportSize({ width: 1280, height: 800 });
  await expect(chip("trivia-night")).toBeDisabled();
  await expect(chip(address)).toHaveText(address);
  // The first free suggestion is preselected: it fills the field and glows, and so does Use Domain.
  await expect(field).toHaveValue(address);
  await expect(chip(address)).toHaveAttribute("aria-pressed", "true");
  await expect(useDomain).toHaveAttribute("data-build-glow", "true");
  const halo = (locator) => locator.evaluate((el) => getComputedStyle(el).boxShadow);
  await expect.poll(() => halo(chip(address)), { message: "the selected chip wears a glow" }).not.toBe("none");
  // Picking the long chip moves the glow, and the field takes its name without the keyboard.
  await chip(longest).click();
  await expect(field).toHaveValue(longest);
  await expect(field).not.toBeFocused();
  await expect(chip(longest)).toHaveAttribute("aria-pressed", "true");
  await expect(chip(address)).toHaveAttribute("aria-pressed", "false");
  // An edit fades it; typing back to the original brings it back.
  await field.fill(`${address}-x`);
  await expect(domainCard.locator("[data-test='build-address-suggestion'][aria-pressed='true']"), "an edit that matches no chip fades the glow").toHaveCount(0);
  await expect.poll(() => halo(chip(address)), { message: "the faded chip has no glow" }).toBe("none");
  await field.fill(address);
  await expect(chip(address), "typed back, the chip glows again").toHaveAttribute("aria-pressed", "true");
  await expect(useDomain).toHaveAttribute("data-build-glow", "true");
  await expect(domainCard.locator("[data-test='build-address-availability']")).toHaveText("Available");
  await useDomain.click();
  await expect(status).toHaveAttribute("data-complete", "true");
  await expect(status.locator("[data-test='build-tile-domain-value']")).toHaveText(`${address}.mcritchie.studio`);
  await expect(status.locator("[data-test='build-summary-build'], [data-test='build-my-app']")).toHaveCount(0);

  // The summary: the app as chosen, and Build My App, which asks for sign-in only now.
  await tapped(page, auth, `Let's use ${address}.mcritchie.studio.`, "Here's your app. Ready when you are.");
  const summary = page.locator("[data-test='build-card-summary']");
  await expect(summary.locator("[data-test='build-summary-title']")).toHaveText("League Standings Hub");
  await expect(summary.locator("[data-test='build-summary-cto']")).toContainText("Marbles");
  await expect(summary.locator("[data-test='build-summary-theme']")).toContainText("Field");
  await expect(summary.locator("[data-test='build-summary-domain']")).toContainText(`${address}.mcritchie.studio`);
  const typed = await page.locator("[data-test='cto-chat-sent']").allTextContents();
  expect(typed.filter((t) => !/^(Let's|My CTO|I'd like)/.test(t.trim())), "the visitor typed only the first message").toEqual([idea]);
  expect(await page.evaluate(() => window.__buildShellMarker), "no reload through the whole intake").toBe("kept");

  // Both themes: the chat and the cards read. A phone: nothing runs off the side.
  await eachTheme(page, async (theme) => {
    for (const selector of ["[data-test='cto-chat-sent']", "[data-test='cto-chat-reply'] p", "[data-test='build-card-summary'] .text-heading", "[data-test='build-status-card'] .text-heading"]) {
      const measured = await page.evaluate(CONTRAST, selector);
      expect(measured.length, `${theme}: ${selector} renders`).toBeGreaterThan(0);
      for (const m of measured) expect(m.ratio, `${theme}: ${selector} "${m.text}"`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    }
  });
  await page.setViewportSize({ width: 360, height: 780 });
  const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(overflow, "nothing runs off the side at 360px").toBeLessThanOrEqual(0);
  await page.setViewportSize({ width: 1280, height: 800 });

  await summary.locator("[data-test='build-summary-build']").click();
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

  // The link returns to the SAME chat, now signed in, and every choice held.
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

  // Build My App: the page moves to the new CTO's chat (a Turbo visit with a view
  // transition, not a reload), Ray's portrait now Marbles's, the status card the app's
  // devops in the Field colours, Ray's handover first and Marbles's code-written greeting
  // already under it: no model ran, nothing is typing.
  await page.evaluate(() => { window.__buildShellMarker = "kept"; });
  await page.locator("[data-test='build-card-summary'] [data-test='build-summary-build']").click();
  await page.waitForURL((u) => u.pathname === `/applications/${address}/chat`);
  expect(await page.evaluate(() => window.__buildShellMarker), "Build My App moves the page without a reload").toBe("kept");
  await expect(page.locator("[data-test='agent-shell'][data-shell='app'] [data-test='agent-caption']")).toContainText("Marbles");
  await expect(page.locator("[data-test='agent-portrait'] [data-test='client-cto-portrait']")).toHaveAttribute("src", /cto_portraits\/meadow/);
  const head = page.locator("[data-test='cto-chat-head'][data-client-cto='true']");
  await expect(head.locator("h1")).toBeVisible();
  await expect(head.locator("[data-test='devops-stage'][data-stage='building']")).toHaveAttribute("data-state", "live");
  await expect(head.locator("[data-test='cto-chat-usage']")).toContainText("Tokens used");
  const handover = page.locator("[data-test='cto-chat-turn']", { has: page.locator("[data-test='cto-chat-handover']") });
  await expect(handover).toContainText("Meet Marbles, your CTO. I'll hand you over.");
  await expect(handover.locator("[data-test='cto-chat-reply']")).toContainText("Hi Jordan, I'm Marbles,");
  await expect(handover.locator("[data-test='cto-chat-reply']")).toContainText("What would you like to see first?");
  await expect(page.locator("[data-test='cto-chat-typing']")).toHaveCount(0);
  await expect(page.locator("turbo-cable-stream-source[channel='CtoChatChannel']")).toHaveAttribute("connected", "");

  // Both themes: the head wears that mode's primary, and the handover, the
  // greeting and the head read. A phone fits.
  await eachTheme(page, async (theme) => {
    await expect(head).toHaveCSS("border-top-color", theme === "dark" ? "rgb(74, 222, 128)" : "rgb(21, 128, 61)");
    for (const selector of ["[data-test='cto-chat-handover'] p", "[data-test='cto-chat-reply'] p", "[data-test='cto-chat-head'] h1"]) {
      const measured = await page.evaluate(CONTRAST, selector);
      expect(measured.length, `${theme}: ${selector} renders`).toBeGreaterThan(0);
      for (const m of measured) expect(m.ratio, `${theme}: ${selector} "${m.text}"`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
    }
  });
  await page.setViewportSize({ width: 390, height: 844 });
  const chatOverflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
  expect(chatOverflow, "the CTO chat fits at 390px").toBeLessThanOrEqual(0);
  expect(pageErrors, report()).toHaveLength(0);
});

// The address moved to /build/<token> in place (replace_url), so Turbo must file
// the page it leaves under THAT address. Filed under "/build" (Turbo's view
// still thought it was there), the draft's thread overwrote the empty /build in
// the snapshot cache, and Back to an earlier /build restored the old thread.
// (Studio.smooth_load sets no-preview, so a forward visit never shows a cached
// page; a restore always does.)
test("leaving /build by a Turbo visit after the first message and coming back never shows the old thread", async ({ page }) => {
  await blockThirdPartyRequests(page);
  const { pageErrors, report } = watchPageErrors(page);
  await page.goto("/build");
  await page.evaluate(() => window.Turbo.visit("/contact"));
  await page.waitForURL((u) => u.pathname === "/contact");
  await page.evaluate(() => window.Turbo.visit("/build"));
  await page.waitForURL((u) => u.pathname === "/build");

  const box = page.getByLabel("Tell Ray what you want to build");
  await box.fill(`A recipe box for my family ${Date.now()}`);
  await page.waitForTimeout(2200); // past the bot shield's two seconds
  await box.press("Enter");
  await expect(page).toHaveURL(/\/build\/[A-Za-z0-9_-]{10,}$/);
  await expect(page.locator("[data-test='build-turn']")).toHaveCount(1);
  const draftPath = new URL(page.url()).pathname;

  // Every render from here, cached or fresh, is recorded with what it drew.
  await page.evaluate(() => {
    window.__renders = [];
    document.addEventListener("turbo:before-render", (event) => {
      window.__renders.push({ path: location.pathname, thread: Boolean(event.detail.newBody.querySelector("[data-test='build-turn']")) });
    });
  });
  await page.evaluate(() => window.Turbo.visit("/contact"));
  await page.waitForURL((u) => u.pathname === "/contact");

  // Back to the draft: its own thread, under its own address.
  await page.goBack();
  await page.waitForURL((u) => u.pathname === draftPath);
  await expect(page.locator("[data-test='build-turn']")).toHaveCount(1);
  // Back past /contact to the first /build: empty, as it was left.
  await page.goBack();
  await page.waitForURL((u) => u.pathname === "/contact");
  await page.goBack();
  await page.waitForURL((u) => u.pathname === "/build");
  await expect(page.getByLabel("Tell Ray what you want to build")).toBeVisible();
  await expect(page.locator("[data-test='build-turn']"), "the empty /build, not the draft's thread").toHaveCount(0);
  const renders = await page.evaluate(() => window.__renders);
  expect(renders.filter((r) => r.thread && r.path !== draftPath), "no other address drew the old thread").toEqual([]);
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
    await page.getByLabel("Tell Ray what you want to build").fill(`Rebuild of my old ${name} app`);
    await page.getByLabel("Tell Ray what you want to build").press("Enter");
    await expect(page).toHaveURL(/\/build\/[A-Za-z0-9_-]{10,}$/);
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
