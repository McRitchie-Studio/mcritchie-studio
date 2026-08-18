const { test, expect } = require("@playwright/test");
const { watchPageErrors } = require("./helpers");

// The Last Release card, and the animations it is allowed to play.
//
// THE BUG. Every finished assembling CI test flashed this card — pop, lift, glow,
// confetti. DeploymentsBroadcaster.ci_progress re-broadcast BOTH release cards on
// every CI upsert (queued AND in_progress AND completed, ~24 per run per repo);
// Release.last_shipped cannot change on a CI tick; so the client received
// byte-identical HTML, had no declared reason and no signature to diff, and its
// fallback branch was `if (!freshDeployGlow(fresh)) burst(fresh, true)` — celebrate.
//
// ASSERTING A NEGATIVE NEEDS PROOF THE EVENT HAPPENED. "No animation is playing"
// is also true of a broadcast that never arrived, so this spec never just waits and
// looks. It tags the live node, fires the spurious redraw, and WAITS FOR THE TAG TO
// DIE — the tag only dies when Turbo actually replaces the slot. Silence is asserted
// against a swap that provably occurred.
//
// Seeded (e2e/seed.rb): a prior SHIPPED Last Release (Dragonite, shipped minutes
// ago) — outside the fresh-deploy window, which is exactly the state in which the
// old fallback was reachable.

// Records every animation class the fx layer applies anywhere on the page, from the
// moment it is installed. A recorder beats a snapshot: these animations self-clear
// on a timer, so sampling the DOM afterwards can miss one that played and finished.
async function recordFx(page) {
  await page.evaluate(() => {
    window.__fxLog = [];
    const note = (el) => {
      for (const cls of el.classList || []) {
        if (cls.startsWith("lbfx-")) window.__fxLog.push((el.id || el.tagName.toLowerCase()) + ":" + cls);
      }
    };
    new MutationObserver((records) => records.forEach((r) => note(r.target)))
      .observe(document.documentElement, { subtree: true, attributes: true, attributeFilter: ["class"] });
  });
}

const fxLog = (page) => page.evaluate(() => window.__fxLog);

test("a spurious redraw of the Last Release card animates NOTHING", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await page.goto("/deployments");
  const lastRelease = page.locator("#last-release");

  // The state the bug needed: a real shipped release, well past its glow window.
  await expect(lastRelease.locator("[data-test='release-mascot']")).toContainText("Dragonite");
  await expect(lastRelease).toHaveAttribute("data-fresh-deploy", "false");
  await expect(lastRelease).toHaveAttribute("data-card-signature", /.+/);

  await recordFx(page);

  // Tag the live node so the replacement is PROVABLE — Turbo swaps the element, so
  // the tag cannot survive a redraw that really happened.
  await lastRelease.evaluate((el) => el.setAttribute("data-e2e-generation", "before"));

  // The exact broadcast a CI upsert used to send: both cards, nothing changed.
  const res = await page.request.post("/dev/board/rebroadcast_release_modules");
  expect(res.ok()).toBeTruthy();

  // The swap landed…
  await expect(lastRelease).not.toHaveAttribute("data-e2e-generation", "before", { timeout: 10_000 });
  await expect(lastRelease.locator("[data-test='release-mascot']")).toContainText("Dragonite");

  // …and the card sat still through it. Settle a beat first: every fx here applies
  // its class synchronously inside a requestAnimationFrame after the render, so one
  // more frame plus slack is long enough for a burst to have shown up in the log.
  await page.waitForTimeout(600);
  expect(await fxLog(page), "the Last Release card must not animate at a redraw that changed nothing").toEqual([]);

  await expect(lastRelease).not.toHaveClass(/lbfx-/);
  await expect(lastRelease).toHaveClass(/opacity-75/);
  expect(pageErrors, report()).toHaveLength(0);
});

test("the router's registry: a moved signature glows, an identical one is silent", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await page.goto("/deployments");
  await expect(page.locator("#last-release")).toHaveAttribute("data-fresh-deploy", "false");

  // Drive the registry directly through the seam the router exports. The two calls
  // differ ONLY in the pre-swap signature, which is the whole question the router
  // exists to answer, and neither depends on wall-clock timing.
  const routed = await page.evaluate(() => {
    const card = document.getElementById("last-release");
    const signature = card.dataset.cardSignature || "";
    return {
      unchanged: window.ReleaseFx.route(card, { signature: signature }, null),
      moved: window.ReleaseFx.route(card, { signature: signature + "-a-different-release" }, null),
      silenced: window.ReleaseFx.route(card, { signature: signature + "-also-different" }, "ci.progress")
    };
  });

  expect(routed.unchanged, "an identical signature is a redraw, not an event").toBeNull();
  expect(routed.moved, "a different release in the slot earns the swap glow").toEqual("release.swapped");
  expect(routed.silenced, "a kind declared silent short-circuits even a real change").toBeNull();

  expect(pageErrors, report()).toHaveLength(0);
});
