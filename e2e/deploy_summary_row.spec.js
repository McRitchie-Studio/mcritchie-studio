const { test, expect } = require("@playwright/test");
const { openDeploySidebar, watchPageErrors } = require("./helpers");

// [e2e] The /deployments SUMMARY ROW — four cards on one line, each opening a sidebar
// with the full detail it stands for (tasks/_deploy_summary_row). Everything here is
// BROWSER behaviour the server tiers cannot see: which sidebar is on screen, how it
// dismisses, that a copy chip inside a card does not also open it, and the Workflows
// carousel turning on its five-minute clock.
//
// Every assertion is about STRUCTURE that holds in any environment — no seeded count
// or release is assumed — so the file is safe wherever the suite runs.

const PANELS = ["apps", "releases", "agents", "devops"];
const toggleFor = (page, panel) =>
  page.locator(`button[data-test='summary-card-toggle'][aria-controls='deploy-sidebar-${panel}']`);

async function openPanels(page) {
  const open = [];
  for (const panel of PANELS) {
    if (await page.locator(`#deploy-sidebar-${panel}`).isVisible()) open.push(panel);
  }
  return open;
}

test("each summary card opens its own sidebar, and only that one", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);
  await page.goto("/deployments");

  const row = page.locator("[data-test='deploy-summary-row']");
  await expect(row.locator("[data-panel]")).toHaveCount(4);
  await expect(row.locator("h3 button[data-test='summary-card-toggle']")).toHaveCount(4);
  expect(await openPanels(page), "nothing is open on arrival").toEqual([]);

  for (const panel of PANELS) {
    await openDeploySidebar(page, panel);
    // Polled: the sidebar being replaced slides out over 200ms, and is still on
    // screen for that long.
    await expect.poll(() => openPanels(page), { message: `clicking the ${panel} card opens its sidebar alone` })
      .toEqual([panel]);
    await expect(toggleFor(page, panel)).toHaveAttribute("aria-expanded", "true");
  }

  // SWITCHING: with Applications open, a click on the Releases card — still in view
  // beside it — swaps the sidebar rather than stacking two, and the outside-click that
  // same click delivers to the Applications sidebar must not undo the new one.
  await openDeploySidebar(page, "apps");
  await page.locator("#release-summary-card [data-test='summary-card-header']").click();
  await expect.poll(() => openPanels(page)).toEqual(["releases"]);
  await expect(toggleFor(page, "releases")).toHaveAttribute("aria-expanded", "true");
  await expect(toggleFor(page, "apps")).toHaveAttribute("aria-expanded", "false");
  expect(pageErrors, report()).toHaveLength(0);
});

test("a sidebar dismisses on Escape, its close button, an outside click, or a second click", async ({ page }) => {
  await page.goto("/deployments");
  const sidebar = page.locator("#deploy-sidebar-releases");

  await openDeploySidebar(page, "releases");
  await page.keyboard.press("Escape");
  await expect(sidebar).toBeHidden();

  await openDeploySidebar(page, "releases");
  await sidebar.locator("[data-test='deploy-sidebar-close']").click();
  await expect(sidebar).toBeHidden();

  await openDeploySidebar(page, "releases");
  await page.locator("h2", { hasText: "Deployments" }).click();
  await expect(sidebar).toBeHidden();

  // The card is a toggle: a second click on its surface closes what the first opened.
  await openDeploySidebar(page, "releases");
  await page.locator("#release-summary-card [data-test='release-summary-next']").click();
  await expect(sidebar).toBeHidden();
  await expect(toggleFor(page, "releases")).toHaveAttribute("aria-expanded", "false");
});

test("the keyboard opens a card's sidebar, and a chip keeps its own Enter", async ({ page }) => {
  await page.goto("/deployments");
  await expect(page.locator("[data-test='deploy-summary']")).toHaveAttribute("data-alpine-ready", "true");
  const toggle = toggleFor(page, "devops");
  await expect(toggle).toHaveAttribute("aria-expanded", "false");

  // The heading is a real button: native Enter, and the card draws its focus ring.
  await toggle.focus();
  await page.keyboard.press("Enter");
  await expect(page.locator("#deploy-sidebar-devops")).toBeVisible();
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await page.keyboard.press("Escape");
  await expect(page.locator("#deploy-sidebar-devops")).toBeHidden();

  // Enter on a focused copy chip copies the chip; it must not also open the Workflows
  // sidebar on its way up (openFrom leaves a button's click to the button).
  const chip = page.locator("#agents-summary-card [data-test='soul-slide'][data-place='active'] button[data-clip]").first();
  await chip.focus();
  await page.keyboard.press("Enter");
  await expect(page.locator("#deploy-sidebar-agents")).toBeHidden();
});

// A copy chip is a real control inside a card that is itself a control. The chip owns
// its click — deploySummary().openFrom ignores clicks that start on a button — so
// copying a command never throws a sidebar over the page.
test("a copy chip in the Workflows card copies without opening the sidebar", async ({ page, context }) => {
  await context.grantPermissions(["clipboard-read", "clipboard-write"]);
  await page.goto("/deployments");

  await expect(page.locator("[data-test='deploy-summary']")).toHaveAttribute("data-alpine-ready", "true");
  const card = page.locator("#agents-summary-card");
  const chip = card.locator("[data-test='soul-slide'][data-place='active'] button[data-row='heartbeat']");
  await chip.click();

  await expect(chip).toHaveAttribute("aria-label", "Copied!");
  await expect(toggleFor(page, "agents")).toHaveAttribute("aria-expanded", "false");
  await expect(page.locator("#deploy-sidebar-agents")).toBeHidden();
});

// THE WHEEL. Five minutes per soul, starting on Turf Monster; the soul in frame leaves
// UPWARD and the next arrives from BELOW, so it reads as a circle. Driven on Playwright's
// clock by the page's own published interval (data-rotate-ms), never a restated number.
test("the Workflows carousel turns every five minutes, sliding up, and holds while hovered", async ({ page }) => {
  // fastForward jumps the clock and fires each due timer once — the wheel counts the time
  // that passed, so one tick after a jump carries the whole jump.
  await page.clock.install();
  await page.goto("/deployments");
  // Where the wheel ENDS is the claim here, not how it animates there. The installed
  // clock also stalls the page's animation timeline, so a slide caught mid-transition
  // reads its START position forever (measured: the active soul still at +100% after the
  // turn). Transitions off, and each slide sits where its place puts it.
  await page.addStyleTag({ content: "[data-test='soul-slide'] { transition: none !important; }" });

  const card = page.locator("#agents-summary-card");
  await expect(card).toHaveAttribute("data-active-agent", "turf-monster");
  const ms = Number(await card.getAttribute("data-rotate-ms"));
  expect(ms, "the operator's spec: five minutes").toBe(300_000);
  const order = (await card.getAttribute("data-agents")).split(",");
  expect(order[0]).toBe("turf-monster");

  // Not yet at half the interval — a wide margin, because the installed clock still
  // flows with real time while the page loads — then turned once it has passed.
  await page.clock.fastForward(ms / 2);
  await expect(card).toHaveAttribute("data-active-agent", "turf-monster");

  await page.clock.fastForward(ms / 2 + 5_000);
  await expect(card).toHaveAttribute("data-active-agent", order[1]);

  const slide = (agent) => card.locator(`[data-test='soul-slide'][data-agent='${agent}']`);
  await expect(slide(order[1])).toHaveAttribute("data-place", "active");
  await expect(slide(order[0])).toHaveAttribute("data-place", "leaving");
  await expect(slide(order[2])).toHaveAttribute("data-place", "waiting");

  // The geometry, not just the labels: the soul that left sits ABOVE the frame, the one
  // waiting sits BELOW it, and only the active one is in it.
  const y = async (agent) =>
    slide(agent).evaluate((el) => {
      const frame = el.parentElement.getBoundingClientRect();
      return Math.round(el.getBoundingClientRect().top - frame.top);
    });
  const geometry = await card.locator("[data-test='soul-slide']").evaluateAll((els) =>
    els.map((el) => {
      const frame = el.parentElement.getBoundingClientRect();
      const box = el.getBoundingClientRect();
      return `${el.dataset.agent}:${el.dataset.place}:${Math.round(box.top - frame.top)}/${Math.round(box.height)}:${getComputedStyle(el).translate}`;
    }).join(" "));
  expect(await y(order[1]), `the active soul is in frame — ${geometry}`).toBe(0);
  expect(await y(order[0]), "the soul that left went UP").toBeLessThan(0);
  expect(await y(order[2]), "the next soul waits BELOW").toBeGreaterThan(0);

  // Off-frame slides cannot be clicked or tabbed to.
  expect(await slide(order[0]).evaluate((el) => el.inert)).toBe(true);
  expect(await slide(order[1]).evaluate((el) => el.inert)).toBe(false);

  // Hovering holds the wheel: the chip under the pointer does not rotate away.
  await card.locator("[data-test='summary-card-header'] h3").hover();
  await page.clock.fastForward(ms * 2);
  await expect(card).toHaveAttribute("data-active-agent", order[1]);

  // …and it resumes once the pointer leaves.
  await page.mouse.move(0, 0);
  await page.clock.fastForward(ms);
  await expect(card).toHaveAttribute("data-active-agent", order[2]);

  // The dots turn it by hand, and wrap round: the last dot's soul, then the first again.
  await card.locator(`[data-test='soul-carousel-dot'][data-agent='${order[4]}']`).click();
  await expect(card).toHaveAttribute("data-active-agent", order[4]);
  await page.mouse.move(0, 0);
  await page.clock.fastForward(ms);
  await expect(card).toHaveAttribute("data-active-agent", order[0]);
});

// "Whichever app test suite restarted most recently jumps to the top." Asserted as the
// ORDER PROPERTY over whatever the environment ingested: every stamped row is newer
// than the one below it, and an app with no ingested suite sits under every app with one.
test("the Applications summary lists the newest suite restart first", async ({ page }) => {
  await page.goto("/deployments");

  const rows = page.locator("[data-test='app-summary-card'] [data-test='app-summary-row']");
  await expect(rows.first()).toBeVisible();
  const stamps = await rows.evaluateAll((els) => els.map((el) => el.dataset.suiteAt || ""));

  const stamped = stamps.filter(Boolean).map((s) => Date.parse(s));
  for (let i = 1; i < stamped.length; i += 1) {
    expect(stamped[i - 1], `row ${i} restarted after the row above it`).toBeGreaterThanOrEqual(stamped[i]);
  }
  const firstBlank = stamps.indexOf("");
  if (firstBlank !== -1) {
    expect(stamps.slice(firstBlank).every((s) => s === ""), "an app with no suite never sits above one with a suite").toBe(true);
  }

  // The sidebar lists the full cards in the SAME order.
  await openDeploySidebar(page, "apps");
  const summaryOrder = await rows.evaluateAll((els) => els.map((el) => el.dataset.repo));
  const detailOrder = await page
    .locator("#app-ladder-detail [data-test='app-ladder-card']")
    .evaluateAll((els) => els.map((el) => el.dataset.repo));
  expect(detailOrder).toEqual(summaryOrder);
});
