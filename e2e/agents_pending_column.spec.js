// [e2e] The Pending agents column of /agents (task pending-agents-page), walked
// the way Alex McRitchie meets it: the seeded Discord bot card (e2e/seed.rb) beside
// the agents table, its row opened to its steps (buttons and copy fields), the Application ID saved, the
// invite built from it, and Done handing the card to the hub's check and Steffon.
//
// [component] At 390px and 1280px, in light and dark, nothing runs off the side,
// the card's text reads at AA on its ground, and on a phone the column comes
// before the long agents grid (on a desktop it is the right-hand half).
//
// WHAT THIS DOES NOT PROVE. No Discord, no 1Password: the links are checked for
// their addresses, never followed, and the verify job's Discord call is not made
// here (the lane has no shared bot token, so the hub's check says so and waits
// for Steffon). PENDING_AGENTS_SHOTS=<dir> also saves the page in both themes and
// widths for a reviewer.
const path = require("path");
const { test, expect } = require("@playwright/test");
const { CONTRAST, eachTheme, TEXT_ON_SURFACE } = require("./contrast");

const SHOTS = process.env.PENDING_AGENTS_SHOTS;
const DESKTOP = { width: 1280, height: 900 };
const PHONE = { width: 390, height: 844 };
const APP_ID = "1560516264378507334";
const CARD = "[data-test='agent-setup-card'][data-agent='mason']";
const TEXT = `${CARD} h4, ${CARD} h5, ${CARD} p, ${CARD} [data-test='agent-setup-badge'], ${CARD} a.btn, ${CARD} button.btn`;

test("the Pending agents column walks a Discord bot card to Done, readable at both widths in both themes", async ({ page }) => {
  await page.goto("/agents");
  const column = page.locator("[data-test='pending-agents']");
  const card = page.locator(CARD);
  await expect(column).toBeVisible();
  await expect(page.locator("[data-test='agents-split']")).toHaveAttribute("data-layout", "split");
  await expect(card).toBeVisible();

  // The row is collapsed until its disclosure opens it; opening one closes any other.
  const toggle = card.locator("[data-test='agent-setup-toggle']");
  await expect(card.locator("[data-test='agent-setup-progress']")).toHaveText("Step 1 of 5");
  await expect(card.locator("[data-test='agent-setup-steps']")).toBeHidden();
  await toggle.click();
  await expect(toggle).toHaveAttribute("aria-expanded", "true");
  await expect(card.locator("[data-test='agent-setup-steps']")).toBeVisible();

  for (const [label, size] of [["390", PHONE], ["1280", DESKTOP]]) {
    await page.setViewportSize(size);
    const overflow = await page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth);
    expect(overflow, `${label}: nothing runs off the side`).toBeLessThanOrEqual(0);
    const pending = await column.boundingBox();
    const grid = await page.locator("[data-test='agents-grid']").boundingBox();
    if (label === "390") {
      expect(pending.y, "on a phone the pending column comes before the agents").toBeLessThan(grid.y);
    } else {
      expect(pending.x, "on a desktop the pending column is the right-hand half").toBeGreaterThan(grid.x);
    }
    await eachTheme(page, async (theme) => {
      const labels = await page.evaluate(CONTRAST, TEXT);
      expect(labels.length, `${theme} ${label}: the card's text is measured`).toBeGreaterThan(10);
      for (const l of labels) {
        expect(l.ratio, `${theme} ${label}: "${l.text.slice(0, 40)}" contrast`).toBeGreaterThanOrEqual(TEXT_ON_SURFACE);
      }
      if (SHOTS) await page.screenshot({ path: path.join(SHOTS, `pending-agents-page-${theme}-${label}.png`), fullPage: label === "1280" });
    });
    await page.evaluate(() => document.documentElement.classList.remove("dark"));
  }
  await page.setViewportSize(DESKTOP);

  // Step 1: the portal opens in a new tab; the name copies; the avatar is the hub's own image.
  await expect(card.locator("[data-test='discord-portal-link']")).toHaveAttribute("href", "https://discord.com/developers/applications");
  await expect(card.locator("[data-test='discord-portal-link']")).toHaveAttribute("target", "_blank");
  await expect(card.locator("[data-test='discord-bot-name']")).toHaveValue("Mason");
  // Step 3: the 1Password deep link to Steffon's empty item; no secret on the page.
  await expect(card.locator("[data-test='op-item-link']")).toHaveAttribute("href", /^https:\/\/start\.1password\.com\/open\/i\?a=a{26}&v=b{26}&i=c{26}&h=my\.1password\.com$/);
  // Step 4 waits for the Application ID; Done is blocked until it is in.
  await expect(card.locator("[data-test='discord-invite-waiting']")).toBeVisible();
  await expect(card.locator("[data-test='agent-setup-done']")).toHaveCount(0);

  await card.locator("form[data-test='discord-app-id-form'] input[type='text']").fill(APP_ID);
  await card.locator("form[data-test='discord-app-id-form'] [type='submit']").click();
  const invite = page.locator(`${CARD} [data-test='discord-invite-link']`);
  await expect(invite).toHaveAttribute("href", new RegExp(`client_id=${APP_ID}.*permissions=274877991936`));

  await page.locator(`${CARD} [data-key='create_app'] [data-test='agent-setup-step-tick']`).click();
  await expect(page.locator(`${CARD} [data-key='create_app']`)).toHaveAttribute("data-state", "done");
  await expect(page.locator(`${CARD} [data-key='reset_token']`)).toHaveAttribute("data-state", "current");

  // Done: every step marked, and the card is no longer Alex McRitchie's turn.
  await page.locator(`${CARD} [data-test='agent-setup-done']`).click();
  await expect(page.locator(CARD)).not.toHaveAttribute("data-status", "pending");
  await expect(page.locator(`${CARD} [data-test='agent-setup-done']`)).toHaveCount(0);
  await expect(page.locator(`${CARD} [data-test='agent-setup-step'][data-state='done']`)).toHaveCount(5);
});
