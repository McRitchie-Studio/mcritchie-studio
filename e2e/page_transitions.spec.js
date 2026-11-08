// [e2e] The hub's page transition on real pages (config.page_transition_direction = :left,
// studio-engine docs/PAGE_TRANSITIONS.md; the engine's own spec drives a lab page). A recorder
// keeps what each view-transition pseudo ran, as only a browser shows it. NOT @qa-readonly in
// spirit: it needs the seeded admin and the cyvasse chat. Forward leaves to the left; Back plays
// the same slide reversed, leaving to the right (engine 0.131.0, "Back"). Do not restore a left
// assertion on a Back.
const { test, expect } = require("@playwright/test");
const { blockThirdPartyRequests, loginWithMagicLink, watchPageErrors, VISITOR } = require("./helpers");

// The lane runs reduced (playwright.config.js). This file is about motion. A bare
// test.use({ reducedMotion }) is ignored, so it has to be contextOptions. The reduced spec turns it back with open().
test.use({ contextOptions: { reducedMotion: "no-preference" } });

const LEFT_OUT = "pt-out-left";
const LEFT_IN = ["pt-in-from-right"];
// Back plays the hub's slide with the direction reversed (studio-engine docs/PAGE_TRANSITIONS.md,
// "Back", Alex McRitchie's ruling of 2026-11-05): a :left slide goes back as slide-right.
const BACK_STYLES = ["::view-transition-new(root) pt-in-from-left", "::view-transition-old(root) pt-out-right"];

// The hub's one style is the slide. The pin makes an engine below Studio.page_transition_style
// draw it too, and goes when the release relocks the engine.
async function record(page, random = 0) {
  await page.addInitScript((value) => {
    // Only for the pick: Turbo draws its history ids from Math.random too.
    window.__random = value;
    window.addEventListener("turbo:before-render", () => {
      const real = Math.random;
      Math.random = () => window.__random;
      setTimeout(() => { Math.random = real; }, 0);
    }, { capture: true });
    window.__seen = [];
    window.__frames = [];
    // One entry per page move drawn. __seen keeps names, so it cannot tell one move from two.
    window.__moves = [];
    const counted = new WeakSet();
    const tick = () => {
      const running = document.getAnimations().filter((a) => (a.effect?.pseudoElement || "").startsWith("::view-transition"));
      for (const animation of running) {
        const key = `${animation.effect.pseudoElement} ${animation.animationName || ""}`;
        if (!window.__seen.includes(key)) window.__seen.push(key);
        if (animation.effect.pseudoElement === "::view-transition-old(root)" && (animation.animationName || "").startsWith("pt-") && !counted.has(animation)) {
          counted.add(animation);
          window.__moves.push(animation.animationName);
        }
      }
      if (running.length) {
        const read = (pseudo) => getComputedStyle(document.documentElement, pseudo).transform;
        window.__frames.push({ root: read("::view-transition-old(root)"), header: read("::view-transition-group(studio-header)") });
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, random);
}

async function open(page, path, { motion = "no-preference", random = 0 } = {}) {
  await blockThirdPartyRequests(page);
  await page.emulateMedia({ reducedMotion: motion });
  await record(page, random);
  await page.goto(path);
  await page.waitForFunction(() => window.Turbo);
}

const settled = (page) => page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));

async function visit(page, path) {
  const load = settled(page);
  await page.evaluate((to) => { window.__seen.length = 0; window.__frames.length = 0; window.__moves.length = 0; window.Turbo.visit(to); }, path);
  await load;
  await expect.poll(() => new URL(page.url()).pathname).toBe(path);
}

async function back(page) {
  await page.evaluate(() => { window.__seen.length = 0; });
  const load = settled(page);
  await page.goBack();
  await load;
}

async function forward(page) {
  await page.evaluate(() => { window.__seen.length = 0; });
  const load = settled(page);
  await page.goForward();
  await load;
}

const seen = (page) => page.evaluate(() => window.__seen);
const pageStyles = (names) => names.filter((name) => /\(root\) pt-/.test(name));

function expectLeftStyle(names) {
  const styles = pageStyles(names);
  expect(styles, JSON.stringify(names)).toContain(`::view-transition-old(root) ${LEFT_OUT}`);
  const incoming = styles.filter((name) => name.startsWith("::view-transition-new(root)")).map((name) => name.split(" ")[1]);
  expect(incoming).toHaveLength(1);
  expect(LEFT_IN).toContain(incoming[0]);
}

test("/ to /chat and back play the one slide, moving left, on both visits", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, "/");
  await expect(page.locator("html")).toHaveAttribute("data-page-transition-direction", "left");
  for (const path of ["/chat", "/"]) {
    await visit(page, path);
    expect(pageStyles(await seen(page)).sort()).toEqual(["::view-transition-new(root) pt-in-from-right", "::view-transition-old(root) pt-out-left"]);
  }
  expect(errors.pageErrors, errors.report()).toEqual([]);
});

// Exact, so a Back that played the forward slide (pt-out-left) fails here.
function expectBackStyle(names) {
  expect(pageStyles(names).sort(), JSON.stringify(names)).toEqual(BACK_STYLES);
}

test("Back plays the slide reversed, moving right", async ({ page }) => {
  await open(page, "/");
  await visit(page, "/chat");
  await back(page);
  expect(new URL(page.url()).pathname).toBe("/");
  expectBackStyle(await seen(page));
});

test("Forward after a Back plays the hub's own left slide", async ({ page }) => {
  await open(page, "/");
  await visit(page, "/chat");
  await back(page);
  await forward(page);
  expect(new URL(page.url()).pathname).toBe("/chat");
  expectLeftStyle(await seen(page));
});

// Playwright turns the back/forward cache off, so this Back is a fresh load: the engine reads
// the pageswap activation, a traverse to an earlier entry, and plays the move reversed.
test("Back by a full load plays the slide reversed too", async ({ page }) => {
  await open(page, "/");
  await Promise.all([page.waitForURL("**/chat"), page.evaluate(() => window.location.assign("/chat"))]);
  await expect.poll(async () => pageStyles(await seen(page)).sort(), "the forward full load").toEqual(["::view-transition-new(root) pt-in-from-right", "::view-transition-old(root) pt-out-left"]);
  await page.goBack({ waitUntil: "load" });
  expect(new URL(page.url()).pathname).toBe("/");
  await expect.poll(async () => pageStyles(await seen(page)).sort(), "the full-load Back").toEqual(BACK_STYLES);
});

test("the navbar and the banner hold still while the page moves", async ({ page }) => {
  await open(page, "/");
  await expect(page.locator("[data-vt-held]")).toHaveCount(1);
  await visit(page, "/chat");
  const names = await seen(page);
  expectLeftStyle(names);
  expect(names.filter((name) => /(old|new)\((studio-bar-stack|studio-header)\)/.test(name)), "the chrome's pictures play nothing").toEqual([]);
  const frames = await page.evaluate(() => window.__frames);
  const distinct = (key) => new Set(frames.map((frame) => frame[key])).size;
  expect(distinct("root"), "the page never moved, so this measured nothing").toBeGreaterThan(1);
  expect(distinct("header"), "the navbar moved").toBe(1);
  await expect(page.locator(".studio-bar-stack").first()).toBeVisible();
});

test("the agent pages keep their morph and play no style", async ({ page }) => {
  await open(page, "/build");
  await visit(page, "/applications/cyvasse/chat");
  const there = await seen(page);
  expect(pageStyles(there), JSON.stringify(there)).toEqual([]);
  expect(there.some((name) => name.startsWith("::view-transition-group(agent-portrait)")), JSON.stringify(there)).toBe(true);
  expect(there.some((name) => name.startsWith("::view-transition-group(agent-composer)")), JSON.stringify(there)).toBe(true);
  // A shared-name visit still has the engine's fade, since the hub's 200ms copy is gone.
  expect(there).toContain("::view-transition-old(root) vt-page-out");
  await visit(page, "/build");
  const home = await seen(page);
  expect(pageStyles(home)).toEqual([]);
  expect(home.some((name) => name.startsWith("::view-transition-group(agent-portrait)")), JSON.stringify(home)).toBe(true);
});

test("leaving an agent page, its named elements move with the page", async ({ page }) => {
  await open(page, "/build");
  await visit(page, "/");
  const names = await seen(page);
  expectLeftStyle(names);
  expect(names.filter((name) => /\(agent-/.test(name)), JSON.stringify(names)).toEqual([]);
});

test("an agent page arrives at its size, not sized when the move ends", async ({ page }) => {
  await open(page, "/");
  await page.evaluate(() => {
    window.__shellTop = null;
    const tick = () => {
      const moving = document.getAnimations().some((a) => (a.animationName || "").startsWith("pt-"));
      const shell = document.querySelector("[data-test='agent-shell']");
      if (moving && shell && window.__shellTop === null) window.__shellTop = shell.style.getPropertyValue("--agent-shell-top");
      requestAnimationFrame(tick);
    };
    tick();
  });
  await visit(page, "/applications/cyvasse/chat");
  expectLeftStyle(await seen(page));
  expect(await page.evaluate(() => window.__shellTop), "the shell moved in unsized").toMatch(/^\d+px$/);
});

test("reduced motion plays nothing, on a page change or between agent pages", async ({ page }) => {
  await open(page, "/", { motion: "reduce" });
  await visit(page, "/chat");
  expect(await seen(page)).toEqual([]);
  await visit(page, "/build");
  expect(await seen(page)).toEqual([]);
  await visit(page, "/applications/cyvasse/chat");
  expect(await seen(page)).toEqual([]);
  await expect(page.locator("[data-test='agent-portrait']")).toBeVisible();
});

test("the sidebar opens and closes after a move", async ({ page }) => {
  const errors = watchPageErrors(page);
  await open(page, "/");
  await visit(page, "/chat");
  const gear = page.locator("header [data-link-sidebar-trigger]").filter({ visible: true }).first();
  await gear.click();
  await expect(gear).toHaveAttribute("aria-expanded", "true");
  await page.keyboard.press("Escape");
  await expect(gear).toHaveAttribute("aria-expanded", "false");
  expect(errors.pageErrors, errors.report()).toEqual([]);
});

test("the real sign-in page plays a left style, and its field takes input", async ({ browser }) => {
  const context = await browser.newContext({ storageState: VISITOR });
  const page = await context.newPage();
  await open(page, "/marketing-kit");
  await visit(page, "/signin");
  expectLeftStyle(await seen(page));
  const email = page.locator("input[type='email']").filter({ visible: true }).first();
  await email.fill("visitor@example.test");
  await expect(email).toHaveValue("visitor@example.test");
  await context.close();
});

// A modal the layout arms on turbo:load, which now comes when the move ends.
test("a modal armed on turbo:load opens after a move, and takes input", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "no-preference" });
  await record(page);
  await loginWithMagicLink(page, "newcomer-move@test.com");
  const field = page.locator("#onboarding-first-name");
  await field.waitFor({ state: "visible" });
  await visit(page, "/chat");
  expectLeftStyle(await seen(page));
  await expect(field).toBeVisible();
  await expect(field).toBeFocused();
  await field.fill("Tess");
  await expect(field).toHaveValue("Tess");
});

// build/_launch stands at the chat's address, and build_launch.js visits that same address, so
// the two pages share a path. An advance visit brings a new page: the portrait and the caption
// morph, and no style plays. Seeded one shot (e2e/seed.rb).
test("the launch panel morphs into the chat at its own address", async ({ browser }) => {
  const chat = "/applications/launch-panel-probe/chat";
  const context = await browser.newContext({ storageState: VISITOR });
  const page = await context.newPage();
  await record(page);
  await loginWithMagicLink(page, "owner@launch-panel.test");
  await page.goto(chat);
  const panel = page.locator("[data-test='build-launch']");
  await expect(panel, "no panel: the flag is spent, so reseed").toBeVisible();
  expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches), "the panel ran reduced").toBe(false);
  await page.evaluate(() => new Promise((done) => {
    document.addEventListener("turbo:visit", () => {
      window.__seen.length = 0;
      document.addEventListener("turbo:load", done, { once: true });
    }, { once: true });
  }));
  await expect(panel).toHaveCount(0);
  await expect(page.locator("[data-test='agent-shell']")).toBeVisible();
  expect(new URL(page.url()).pathname).toBe(chat);
  const names = await seen(page);
  expect(pageStyles(names), JSON.stringify(names)).toEqual([]);
  expect(names.some((name) => name.startsWith("::view-transition-group(agent-portrait)")), JSON.stringify(names)).toBe(true);
  expect(names.some((name) => name.startsWith("::view-transition-group(agent-caption)")), JSON.stringify(names)).toBe(true);
  await context.close();
});

// A GET that redirects: Turbo renders the response, then visits the final address with that same
// response. /contact is the control: one move, so the count can read one.
test("a GET that redirects moves the page once", async ({ browser }) => {
  const context = await browser.newContext({ storageState: VISITOR });
  const page = await context.newPage();
  await open(page, "/marketing-kit");
  await visit(page, "/contact");
  expect(await page.evaluate(() => window.__moves), "the control").toHaveLength(1);
  const load = settled(page);
  await page.evaluate(() => { window.__seen.length = 0; window.__moves.length = 0; window.Turbo.visit("/login"); });
  await load;
  expect(new URL(page.url()).pathname).toBe("/signin");
  expect(await page.evaluate(() => window.__moves)).toHaveLength(1);
  await context.close();
});
