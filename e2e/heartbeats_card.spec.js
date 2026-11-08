const { test, expect } = require("@playwright/test");
const { openDeploySidebar } = require("./helpers");

// The /deployments WORKFLOWS surface: EIGHT soul launchers — Turf Monster (live scores),
// Carl (review), Avi (assemble/QA), Steffon (ship + infra sweep), Mason, Alex, Mack and the general
// Pokémon (wrap-it-up). Since the
// summary row (2026-09-18) they are drawn twice: ONE soul at a time on the Workflows
// summary card's carousel, and every soul with every command in the Workflows sidebar,
// one soul at a time there too, cycled by Previous / Next (2026-11-07).
// This is the browser-level check that the acts render under the RIGHT souls end to end,
// in the sidebar the operator actually opens.
test("the Workflows sidebar lists eight soul launchers with their acts", async ({ page }) => {
  await page.goto("/deployments");

  // The carousel starts on Turf Monster, the operator's spec.
  const summary = page.locator("#agents-summary-card");
  await expect(summary).toHaveAttribute("data-active-agent", "turf-monster");
  await expect(summary.locator("[data-test='soul-slide'][data-place='active']")).toHaveAttribute("data-agent", "turf-monster");

  await openDeploySidebar(page, "agents");
  const card = page.locator("#deploy-sidebar-agents [data-test='heartbeats-card']");
  await expect(card).toBeVisible();

  await expect(card.locator("[data-test='heartbeat-launcher']")).toHaveCount(8);

  // The sidebar shows ONE soul at a time; a dot brings a soul into view.
  const show = async (agent) => {
    await card.locator(`[data-test='workflows-dot'][data-agent='${agent}']`).click();
    await expect(card).toHaveAttribute("data-active-agent", agent);
  };

  // Carl owns review: his row carries the pr-review + pr-review-slow chips.
  await show("carl");
  const carl = card.locator("[data-test='heartbeat-launcher'][data-agent='carl']");
  await expect(carl).toHaveCount(1);
  await expect(carl.locator("button[data-clip='Carl Heartbeat']")).toBeVisible();
  await expect(carl.locator("button[data-clip='pr-review']")).toBeVisible();
  await expect(carl.locator("button[data-clip='pr-review-slow']")).toBeVisible();

  // Avi owns qa-release (assemble + QA).
  await show("avi");
  const avi = card.locator("[data-test='heartbeat-launcher'][data-agent='avi']");
  await expect(avi.locator("button[data-clip='qa-release']")).toBeVisible();
  // intent-scout: the manual launch for a task begin could not scout.
  await expect(avi.locator("button[data-clip='intent-scout']")).toBeVisible();

  // Steffon owns production-deploy + clean-infra. archive-shipped is NOT a chip:
  // production-deploy runs it as its final step, so the cleaning rides every release
  // instead of waiting to be remembered. It stays invocable by name.
  await show("steffon");
  const steffon = card.locator("[data-test='heartbeat-launcher'][data-agent='steffon']");
  await expect(steffon.locator("button[data-clip='production-deploy']")).toBeVisible();
  await expect(steffon.locator("button[data-clip='clean-infra']")).toBeVisible();
  await expect(page.locator("button[data-clip='archive-shipped']")).toHaveCount(0);

  // Mason's third act is visible here — no compact toggle hides a chip.
  await show("mason");
  const mason = card.locator("[data-test='heartbeat-launcher'][data-agent='mason']");
  await expect(mason.locator("button[data-clip='full-cycle']")).toBeVisible();
  // ship-clock, the typing-to-shipping benchmark, is Mason's since 2026-10-28.
  await expect(mason.locator("button[data-clip='ship-clock']")).toBeVisible();
  // Alex's chip: focus-session, the Sales/Marketing seat's epic with Alex McRitchie.
  await show("alex");
  const alex = card.locator("[data-test='heartbeat-launcher'][data-agent='alex']");
  await expect(alex.locator("button[data-clip='focus-session']")).toBeVisible();

  // Turf Monster owns the live score watch.
  await show("turf-monster");
  const turf = card.locator("[data-test='heartbeat-launcher'][data-agent='turf-monster']");
  await expect(turf.locator("button[data-clip='Turf Monster Heartbeat']")).toBeVisible();
  await expect(turf.locator("button[data-clip='live-score-watch']")).toBeVisible();

  // Mack carries the monthly close.
  await show("mack");
  const mack = card.locator("[data-test='heartbeat-launcher'][data-agent='mack']");
  await expect(mack.locator("button[data-clip='Mack Heartbeat']")).toBeVisible();
  await expect(mack.locator("button[data-clip='close-the-month']")).toBeVisible();

  // The general Pokémon has no HEARTBEAT: its row is the wrap-it-up act alone.
  await show("pokemon");
  const pokemon = card.locator("[data-test='heartbeat-launcher'][data-agent='pokemon']");
  await expect(pokemon.locator("button[data-clip='wrap-it-up']")).toBeVisible();
  await expect(pokemon.locator("button[data-row='heartbeat']")).toHaveCount(0);
});

// THE SIDEBAR'S WHEEL, TURNED BY HAND. Next walks the souls in order and wraps from the
// last back to the first; Previous wraps the other way. Exactly one soul is shown, and
// its name links to its agent page in a new tab.
test("the Workflows sidebar cycles souls with Next and Previous, wrapping", async ({ page }) => {
  await page.goto("/deployments");
  await openDeploySidebar(page, "agents");
  const card = page.locator("#deploy-sidebar-agents [data-test='heartbeats-card']");
  const order = (await card.getAttribute("data-agents")).split(",");
  expect(order.length).toBe(8);
  const next = card.getByRole("button", { name: "Next agent" });
  const prev = card.getByRole("button", { name: "Previous agent" });
  const shown = card.locator("[data-test='workflows-soul']:visible");

  const expectShowing = async (agent, position) => {
    await expect(card).toHaveAttribute("data-active-agent", agent);
    await expect(shown).toHaveCount(1);
    await expect(shown).toHaveAttribute("data-agent", agent);
    await expect(card.locator("[data-test='workflows-position']")).toHaveText(`${position} of ${order.length}`);
  };

  // The toggle click came through the card, whose wheel starts on Turf Monster.
  const start = order.indexOf("turf-monster");
  await expectShowing(order[start], start + 1);

  // Keyboard reachable: focus Next and press Enter for every turn of the full circle.
  await next.focus();
  for (let step = 1; step <= order.length; step++) {
    await page.keyboard.press("Enter");
    const i = (start + step) % order.length;
    await expectShowing(order[i], i + 1);
  }

  // Previous wraps the other way: from the first soul back to the last.
  await card.locator(`[data-test='workflows-dot'][data-agent='${order[0]}']`).click();
  await expectShowing(order[0], 1);
  await prev.click();
  await expectShowing(order[order.length - 1], order.length);

  // The shown soul's name opens its agent page in a new tab.
  const link = shown.locator("a[data-test='heartbeat-agent-link']");
  await expect(link).toHaveAttribute("target", "_blank");
  await expect(link).toHaveAttribute("rel", /noopener/);
  await expect(link).toHaveAttribute("href", `/agents/${order[order.length - 1]}`);
});

// THE CARD HANDS OVER ITS SOUL. A dot on the summary card turns the wheel; the sidebar
// then opens on that soul rather than at the top of the list.
test("the Workflows sidebar opens on the soul the card has in frame", async ({ page }) => {
  await page.goto("/deployments");
  await expect(page.locator("[data-test='deploy-summary']")).toHaveAttribute("data-alpine-ready", "true");
  const summary = page.locator("#agents-summary-card");
  await summary.locator("[data-test='soul-carousel-dot'][data-agent='carl']").click();
  await expect(summary).toHaveAttribute("data-active-agent", "carl");

  // The card's name link is a new-tab link too, and owns its click (no sidebar).
  const cardLink = summary.locator("[data-test='soul-slide'][data-place='active'] a[data-test='heartbeat-agent-link']");
  await expect(cardLink).toHaveAttribute("href", "/agents/carl");
  await expect(cardLink).toHaveAttribute("target", "_blank");
  // A click opens the agent page in a NEW tab and leaves the board and sidebar alone.
  const [tab] = await Promise.all([page.context().waitForEvent("page"), cardLink.click()]);
  await tab.waitForLoadState("domcontentloaded");
  expect(new URL(tab.url()).pathname).toBe("/agents/carl");
  await tab.close();
  expect(new URL(page.url()).pathname).toBe("/devops");
  await expect(page.locator("#deploy-sidebar-agents")).toBeHidden();

  await openDeploySidebar(page, "agents");
  const card = page.locator("#deploy-sidebar-agents [data-test='heartbeats-card']");
  await expect(card).toHaveAttribute("data-active-agent", "carl");
  await expect(card.locator("[data-test='workflows-soul']:visible")).toHaveAttribute("data-agent", "carl");
});
