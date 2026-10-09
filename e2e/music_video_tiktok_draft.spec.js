// [e2e] Draft to TikTok, as the operator meets it on an alt video's clip
// builder: every clip card shows its slug with a copy control; the button is
// off for a clip with no generated version; pressing it on a clip with a
// primary version submits once however often it is pressed and records one
// attempt, and the card then shows the attempt
// settle to "Sent to your TikTok inbox" with the caption the code wrote, its Copy,
// and TikTok's publish id. Wholly synthetic data, seeded by e2e/seed.rb from
// db/seeds/data/tiktok_draft_video.rb: its own video, so this never meets the
// specs that work on the other demos.
//
// WHAT THIS DOES NOT PROVE. Nothing here reaches TikTok, R2 or ESPN: the lane's
// stand-in answers for TikTok and the bucket (config/initializers/
// tiktok_draft_stand_in.rb) and the same fixed season the X card reads answers
// for ESPN (every team 3-1). The real upload, its chunk rules and TikTok's
// refusals are pinned in test/services/tiktok/inbox_upload_test.rb.
// Everything else on this path is real: the button, the record, the caption
// recipe, the job, the states and the page.
const path = require("path");
const fs = require("fs");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const MP4 = path.join(__dirname, "..", "test", "fixtures", "files", "stitch_demo.mp4");
const SLUG = "test-artist-a-tiktok-demo-alt-1-clip-01";

test("the operator drafts a clip to TikTok and sees the recorded draft", async ({ page }) => {
  const body = fs.readFileSync(MP4);
  await page.route("https://fixture.invalid/**", (route) => route.fulfill({ status: 200, contentType: "video/mp4", body }));
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-artist-a-tiktok-demo/alt_videos/1");

  const card = (n) => page.locator(`[data-test='alt-clip'][data-ordinal='${n}']`);
  const tiktok = (n) => card(n).locator("[data-test='clip-tiktok']");

  // Every card names its clip: the slug the tiktok-draft SOP takes, with a copy control.
  await expect(card(1).locator("[data-test='clip-slug']")).toHaveText(SLUG);
  await expect(card(2).locator("[data-test='clip-slug']")).toHaveText("test-artist-a-tiktok-demo-alt-1-clip-02");
  await card(1).locator("[data-test='clip-slug-copy']").click();
  await expect(card(1).locator("[data-test='clip-slug-row']")).toContainText(/Copied|Selected: copy it from here/);

  // No generated version, no draft: the button is off and says why.
  await expect(tiktok(2)).toHaveAttribute("data-enabled", "false");
  await expect(tiktok(2).getByRole("button", { name: "Draft to TikTok" })).toBeDisabled();
  await expect(tiktok(2).locator("[data-test='clip-tiktok-blocker']")).toContainText("No generated version yet");

  // Clip 1 has a primary version. First, the press guard, measured in the page
  // with the submit caught before it leaves (a listener added after Alpine's
  // runs after it and sees what Alpine let through): one press submits and
  // turns the button off, a second press does nothing, and a submit that gets
  // past the button (Enter, a script) is stopped by the form itself. It is
  // measured here, not by a double click, because Chromium folds two submits
  // made in one tick into a single navigation: a dblclick sends one request
  // with or without the guard.
  await expect(tiktok(1)).toHaveAttribute("data-attempts", "0");
  const form = tiktok(1).locator("form[data-test='clip-tiktok-draft']");
  const presses = await form.evaluate(async (el) => {
    const button = el.querySelector("button");
    let submitted = 0;
    const count = (event) => { if (!event.defaultPrevented) submitted += 1; event.preventDefault(); };
    el.addEventListener("submit", count);
    button.click();
    await new Promise((resolve) => setTimeout(resolve, 100));
    const afterFirst = { disabled: button.disabled, label: button.textContent.trim() };
    button.click();
    el.requestSubmit();
    await new Promise((resolve) => setTimeout(resolve, 100));
    el.removeEventListener("submit", count);
    window.Alpine.$data(el).sending = false; // hand the form back as it was
    return { submitted, afterFirst };
  });
  expect(presses).toEqual({ submitted: 1, afterFirst: { disabled: true, label: "Sending…" } });

  // Now the real press: one attempt.
  await expect(tiktok(1).getByRole("button", { name: "Draft to TikTok" })).toBeEnabled();
  await tiktok(1).getByRole("button", { name: "Draft to TikTok" }).click();
  await expect(page.locator("body")).toContainText("Clip 1 is on its way to your TikTok inbox");
  await expect(tiktok(1)).toHaveAttribute("data-attempts", "1");

  // The upload runs in the background; the card shows it once it has settled.
  await expect(async () => {
    await page.reload();
    await expect(tiktok(1).locator("[data-test='clip-tiktok-latest']")).toHaveAttribute("data-state", "delivered");
  }).toPass({ timeout: 20_000 });

  const latest = tiktok(1).locator("[data-test='clip-tiktok-latest']");
  await expect(latest.locator("[data-test='clip-tiktok-state']")).toHaveText("Sent to your TikTok inbox");
  await expect(latest.locator("[data-test='clip-tiktok-caption-hint']")).toContainText("TikTok did not receive this caption");
  await expect(latest.locator("[data-test='clip-tiktok-caption']")).toHaveText("Bills 3-1 #nfl #nfltiktok #footballtiktok #bills #fyp");
  await expect(latest.locator("[data-test='clip-tiktok-copy']")).toBeVisible();
  await expect(latest.locator("[data-test='clip-tiktok-publish-id']")).toContainText("stand-in-");
  await expect(latest.locator("[data-test='clip-tiktok-stand-in']")).toBeVisible();
  await expect(latest.locator("[data-test='clip-tiktok-team-rule']")).toContainText("Sample Rusher Eta, the clip's target, by the look's team");
  await expect(latest).toContainText("Version 1");

  // The caption travels only by this button (TikTok does not receive it), so it
  // says "Copied" only when the browser took the text. First the control: the
  // clipboard takes it.
  const copy = latest.locator("[data-test='clip-tiktok-copy']");
  const manual = latest.locator("[data-test='clip-tiktok-copy-manual']");
  const clipboard = (takes) => page.evaluate((ok) => {
    window.__clipboardAsked = 0;
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: {
      writeText: () => { window.__clipboardAsked += 1; return ok ? Promise.resolve() : Promise.reject(new DOMException("blocked", "NotAllowedError")); },
    } });
  }, takes);
  await clipboard(true);
  await copy.click();
  await expect(copy).toHaveText("Copied");
  await expect(manual).toBeHidden();
  await expect(copy).toHaveText("Copy caption");

  // Now the browser blocks both ways: the clipboard API rejects and
  // execCommand("copy") answers false. The card says so, selects the caption
  // to be copied by hand, and never says "Copied".
  await clipboard(false);
  await page.evaluate(() => {
    window.__labels = [];
    const button = document.querySelector("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-tiktok-copy']");
    new MutationObserver(() => window.__labels.push(button.textContent.trim())).observe(button, { subtree: true, childList: true, characterData: true });
    document.execCommand = () => { window.__execAsked = (window.__execAsked || 0) + 1; return false; };
  });
  await copy.click();
  await expect(manual).toBeVisible();
  await expect(manual).toHaveText("Copy is blocked here: the caption is selected, so copy it from there.");
  // Both ways were tried, and the label never left "Copy caption" on the way here.
  expect(await page.evaluate(() => [window.__clipboardAsked, window.__execAsked, window.__labels])).toEqual([1, 1, []]);
  await expect(copy).toHaveText("Copy caption");
  expect(await page.evaluate(() => window.getSelection().toString())).toBe("Bills 3-1 #nfl #nfltiktok #footballtiktok #bills #fyp");
});
