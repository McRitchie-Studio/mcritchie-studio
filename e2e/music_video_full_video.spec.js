// [e2e] An alt video's final stitch, as the operator meets it: "Generate full
// video" is off until every clip has a primary version and none is flagged;
// pressing it records a numbered stitch that runs in the background while the
// page says so; the page notices it finish and shows it with a player and a
// download; and a later version, or a regenerate flag, marks it stale. Wholly
// synthetic data, seeded by e2e/seed.rb from db/seeds/data/stitch_ready_video.rb
// (its alt video 1): its own video, so this never meets the specs that work on
// the tiled demo.
//
// WHAT THIS DOES NOT PROVE. The lane has no ffmpeg and no bucket, so the
// stitcher is a stand-in that waits three seconds and reports a file
// (config/initializers/e2e_video_storage.rb); no MP4 is made or played here,
// and Chromium may not decode H.264 anyway. The ffmpeg work (the crossfade,
// the source audio, the exact length) is proven against real ffmpeg in
// test/lib/music_videos/stitcher_test.rb. Everything else on this path is
// real: the button, the request, the job, the states, the poll, the page.
const path = require("path");
const fs = require("fs");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const MP4 = path.join(__dirname, "..", "test", "fixtures", "files", "stitch_demo.mp4");

test("the operator generates the full video, and a later version or flag marks it stale", async ({ page }) => {
  const body = fs.readFileSync(MP4);
  await page.route("https://fixture.invalid/**", (route) => route.fulfill({ status: 200, contentType: "video/mp4", body }));
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-artist-a-stitch-demo/alt_videos/1");

  const panel = page.locator("[data-test='full-video']");
  const generate = panel.locator("[data-test='full-video-generate']");
  const row = (n) => page.locator(`[data-test='alt-clip'][data-ordinal='${n}']`);
  // Choosing the file (the drop zone's click path) uploads it at once. Alpine
  // binds the drop zone after the page's markup is there (it drops x-cloak as
  // it does), and a file chosen before that is never sent.
  const upload = async (n) => {
    await expect(row(n).locator("[data-test='clip-drop-form'] [x-cloak]")).toHaveCount(0);
    const before = await row(n).locator("[data-test='clip-version']").count();
    await row(n).locator("[data-test='clip-file']").setInputFiles(MP4);
    await expect(row(n).locator("[data-test='clip-version']")).toHaveCount(before + 1);
    return row(n).getAttribute("data-primary");
  };

  // Ready exactly when every clip has a version: on a fresh lane clip 2 has none.
  await expect(page.locator("[data-test='alt-clip']")).toHaveCount(2);
  const chunkTwoHasTake = Number(await row(2).getAttribute("data-primary")) > 0;
  await expect(panel).toHaveAttribute("data-ready", String(chunkTwoHasTake));
  if (!chunkTwoHasTake) {
    await expect(generate).toBeDisabled();
    await expect(panel.locator("[data-test='full-video-blocker']")).toHaveText("Not yet: Clip 2 has no generated version.");
  }

  // A flagged clip holds the stitch back whatever versions there are.
  await row(2).locator("[data-test='clip-regenerate-input']").fill("the jersey flickers");
  await row(2).getByRole("button", { name: "Request regenerate" }).click();
  await expect(panel).toHaveAttribute("data-ready", "false");
  await expect(generate).toBeDisabled();
  await expect(panel.locator("[data-test='full-video-blocker']")).toContainText("Clip 2 is flagged for a regenerate");

  // The upload that answers the flag is the last thing missing: the button comes on.
  const takeTwo = await upload(2);
  const takeOne = await row(1).getAttribute("data-primary");
  await expect(panel).toHaveAttribute("data-ready", "true");
  await expect(panel.locator("[data-test='full-video-blocker']")).toHaveCount(0);
  await expect(generate).toBeEnabled();

  // Generate: a numbered stitch is recorded and runs in the background; the page says so.
  const earlier = Number((await panel.getAttribute("data-latest")) || 0);
  await generate.click();
  const open = panel.locator("[data-test='full-video-open']");
  await expect(open).toBeVisible();
  const number = Number(await open.getAttribute("data-number"));
  expect(number).toBeGreaterThan(earlier);
  await expect(open).toContainText(new RegExp(`Stitch ${number}\\s+is (queued on this hub|stitching now) \\(versions ${takeOne}, ${takeTwo}\\)`));
  await expect(page.locator("body")).toContainText(`Stitch ${number} requested: stitching now.`);
  await expect(generate).toBeDisabled();
  await expect(panel.locator(`[data-test='full-video-latest'][data-number='${number}']`)).toHaveCount(0);

  // The page's own poll notices the stitch finish and offers it; it never reloads by itself.
  const changed = open.locator("[data-test='full-video-changed']");
  await expect(changed).toBeVisible({ timeout: 20_000 });
  await changed.getByRole("button", { name: "Show it" }).click();

  // Done: the latest stitch, current, with a player and a download named for its number.
  const latest = panel.locator(`[data-test='full-video-latest'][data-number='${number}']`);
  const file = `stitch_demo_alt_01_stitched_${String(number).padStart(2, "0")}.mp4`;
  await expect(latest).toHaveAttribute("data-stale", "false");
  await expect(latest.locator("[data-test='full-video-current']")).toHaveText("Current");
  await expect(latest.locator("[data-test='full-video-player']")).toHaveAttribute("src", new RegExp(`stitched/${file}`));
  await expect(latest.locator("[data-test='full-video-player']")).toHaveAttribute("controls", "");
  await expect(latest.locator("[data-test='full-video-facts']")).toContainText("45.00 s · 320×180 · 12 fps");
  const download = latest.locator("[data-test='full-video-download']");
  await expect(download).toHaveText(`Download stitch ${number}`);
  await expect(download).toHaveAttribute("download", file);
  await expect(download).toHaveAttribute("href", new RegExp(`stitched/${file}.*response-content-disposition=attachment`));
  await expect(latest.locator("[data-test='full-video-takes']")).toContainText(`Versions ${takeOne}, ${takeTwo}`);
  await expect(panel.locator("[data-test='full-video-open']")).toHaveCount(0);
  await expect(generate).toBeEnabled();

  // A newer version on any clip: the stitch stays on show, marked stale, with the reason.
  const newer = await upload(1);
  await expect(latest).toHaveAttribute("data-stale", "true");
  await expect(latest.locator("[data-test='full-video-stale']")).toHaveText("Stale");
  await expect(latest.locator("[data-test='full-video-stale-why']"))
    .toContainText(`clip 1 is now on version ${newer} (stitched with version ${takeOne})`);
  await expect(latest.locator("[data-test='full-video-player']")).toBeVisible();
  await expect(generate).toBeEnabled();

  // A regenerate flag is a second reason, and it turns the button off until it is answered.
  await row(2).locator("[data-test='clip-regenerate-input']").fill("one more pass");
  await row(2).getByRole("button", { name: "Request regenerate" }).click();
  await expect(latest.locator("[data-test='full-video-stale-why']")).toContainText("clip 2 is flagged for a regenerate");
  await expect(generate).toBeDisabled();
  await row(2).locator("[data-test='clip-regenerate-clear'] button").click();
  await expect(latest.locator("[data-test='full-video-stale-why']")).not.toContainText("flagged");
  await expect(generate).toBeEnabled();
});
