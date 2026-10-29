// [e2e] The brand page's Motion tab (task logo-motion-presets; epic logo-motion, phase 1): it plays a preset on the
// brand's own kit logo, measured at runtime (the same presets on two brands, Turf Monster and Commercial Welding v2,
// with no per-brand code), the scrubber steps through it, reduced motion holds the finished logo, and Save as default
// stores the kit's motion, which the kit status line then names. The save is cleared at the end, so the other /logos
// specs see no motion.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function open(page, path) {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto(path);
}

const player = (page) => page.locator("[data-test='motion-player']");
const timeOf = (page) => page.evaluate(() => document.querySelector("[data-logo-motion]").motionPlayer.tl.time());

async function ready(page) {
  await expect(player(page)).toHaveAttribute("data-motion-ready", "true", { timeout: 15_000 });
  await expect(page.locator("[data-test='motion-stage']")).toBeVisible();
  await expect(page.locator("[data-test='motion-still']")).toBeHidden();
}

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("the Motion tab plays Particle resolve on Turf Monster's kit logo, and the scrubber steps through it", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await open(page, "/logos/turf?type=motion&preset=particle_resolve");
  await ready(page);
  const svg = page.locator("[data-test='motion-stage'] svg[data-test='motion-svg']");
  await expect(svg).toHaveCount(1);
  // The kit logo is split into its parts: the icon's three layers and the name's letters, each in its own group.
  expect(await svg.evaluate((el) => el.querySelectorAll(":scope > g, :scope > g > g").length)).toBeGreaterThan(10);
  await expect(page.locator("[data-test='motion-stage'] canvas")).toHaveCount(1);

  await page.locator("[data-test='motion-scrub']").fill("500");
  await expect(player(page)).toHaveAttribute("data-motion-state", "paused");
  const half = await timeOf(page);
  expect(half).toBeGreaterThan(1);
  await page.locator("[data-test='motion-replay']").click();
  await expect.poll(() => timeOf(page)).toBeLessThan(half);
  await expect(player(page)).toHaveAttribute("data-motion-state", "done", { timeout: 15_000 });
  expect(errors).toEqual([]);
});

test("the same preset plays on Commercial Welding v2's Navbar Logo, and Save as default stores the kit's motion", async ({ page }) => {
  const errors = [];
  page.on("pageerror", (error) => errors.push(error.message));
  await open(page, "/logos/welding_v2?type=motion&preset=particle_resolve&logo=navbar");
  await ready(page);
  await expect(page.locator("[data-test='motion-preset'][data-preset='weight_flick']")).toHaveCount(0);
  await expect(page.locator("[data-test='kit-status']")).toHaveText("Kit: not saved yet");

  await page.locator("[data-test='motion-save']").click();
  await page.waitForURL(/\/logos\/welding_v2\?type=motion#motion$/);
  await expect(page.getByText("Saved the kit's motion: Particle resolve on the Navbar Logo.")).toBeVisible();
  await expect(page.locator("[data-test='kit-status']")).toContainText("motion: Particle resolve on the Navbar Logo");
  await expect(player(page)).toHaveAttribute("data-preset", "particle_resolve");
  await expect(player(page)).toHaveAttribute("data-logo", "navbar");
  await expect(page.locator("[data-test='motion-default-state']")).toHaveAttribute("data-state", "shown");
  await ready(page);

  await page.locator("[data-test='motion-clear']").click();
  await expect(page.getByText("Cleared the kit's motion.")).toBeVisible();
  await expect(page.locator("[data-test='kit-status']")).not.toContainText("motion:");
  expect(errors).toEqual([]);
});

test("under reduced motion the stage holds the finished logo and Play runs it", async ({ page }) => {
  await page.emulateMedia({ reducedMotion: "reduce" });
  await open(page, "/logos/studio?type=motion&preset=weight_flick");
  await ready(page);
  await expect(player(page)).toHaveAttribute("data-motion-state", "done");
  await expect(page.locator("[data-test='motion-toggle']")).toHaveText("Play");
  await expect(page.locator("[data-test='motion-reduced-note']")).toBeVisible();
  await page.locator("[data-test='motion-toggle']").click();
  await expect(player(page)).toHaveAttribute("data-motion-state", "playing");
});
