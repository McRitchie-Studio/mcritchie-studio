// [e2e] The clip builder's round trip on a tiled video: the operator builds an
// alt video, DROPS a generated MP4 onto a clip (it becomes the primary
// version), drops a second, puts the first back in front, flags another clip,
// and watches the full video in its modal across a handover. Wholly synthetic
// data, seeded by e2e/seed.rb from db/seeds/data/tiled_video.rb. No bucket is
// reached: the upload is dropped by the lane's stand-in store, and every
// signed URL (fixture.invalid) is answered here with one small test-pattern MP4.
//
// The lane's Chromium may not decode H.264, so nothing here reads a video's own
// clock. The player then runs on its timer instead of the source audio, which
// is the same path a video with unreachable audio takes.
const path = require("path");
const fs = require("fs");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const MP4 = path.join(__dirname, "..", "test", "fixtures", "files", "stitch_demo.mp4");

// Drop a file on a drop zone the way a desktop drag does: a real drop event
// carrying a DataTransfer with the file in it.
async function dropFile(page, zone, name, bytes) {
  const transfer = await page.evaluateHandle(({ name, b64 }) => {
    const raw = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
    const carry = new DataTransfer();
    carry.items.add(new File([raw], name, { type: name.endsWith(".mp4") ? "video/mp4" : "text/plain" }));
    return carry;
  }, { name, b64: bytes.toString("base64") });
  await zone.dispatchEvent("dragenter", { dataTransfer: transfer });
  await zone.dispatchEvent("drop", { dataTransfer: transfer });
}

test("the operator drops versions onto clips and watches the full video", async ({ page }) => {
  const body = fs.readFileSync(MP4);
  await page.route("https://fixture.invalid/**", (route) => route.fulfill({ status: 200, contentType: "video/mp4", body }));
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-artist-a-tiled-demo");
  await page.locator("[data-test='cast-progress']").getByRole("button", { name: "Build Clips" }).click();
  await expect(page.locator("[data-test='alt-clip']")).toHaveCount(4);

  const card = (n) => page.locator(`[data-test='alt-clip'][data-ordinal='${n}']`);
  const zone = (n) => card(n).locator("[data-test='clip-drop']");

  // The drop zone refuses a non-MP4 in the browser, before a byte is sent.
  await dropFile(page, zone(2), "notes.txt", Buffer.from("not a video"));
  await expect(card(2).locator("[data-test='clip-drop-error']")).toHaveText("That file is not an MP4.");
  await expect(card(2).locator("[data-test='clip-versions-empty']")).toBeVisible();

  // Drop the generated MP4 on clip 2: it uploads at once as version 1, primary.
  await dropFile(page, zone(2), "generated.mp4", body);
  await expect(card(2)).toHaveAttribute("data-primary", "1");
  await expect(card(2).locator("[data-test='clip-state']")).toHaveText("Version 1 primary");
  await expect(card(2).locator("[data-test='clip-version'][data-number='1']"))
    .toHaveAttribute("data-key", /alt_videos\/\d\d\/clips\/tiled_demo_alt_\d\d_chunk_02_0020_0045_v01\.mp4$/);

  // A second drop is version 2 and takes over; version 1 is kept and can be put back.
  await dropFile(page, zone(2), "generated-again.mp4", body);
  await expect(card(2)).toHaveAttribute("data-primary", "2");
  await expect(card(2).locator("[data-test='clip-version']")).toHaveCount(2);
  await card(2).locator("[data-test='clip-version'][data-number='1'] [data-test='clip-make-primary'] button").click();
  await expect(card(2)).toHaveAttribute("data-primary", "1");
  await expect(card(2).locator("[data-test='clip-version'][data-number='1']")).toHaveAttribute("data-primary", "true");
  await expect(card(2).locator("[data-test='clip-version'][data-number='2']")).toHaveAttribute("data-primary", "false");
  await expect(page.locator("[data-test='alt-progress-count']")).toHaveText("1 of 4");

  // Flag clip 3: it joins the flagged list with its note, then clears.
  await card(3).locator("[data-test='clip-regenerate-input']").fill("the jersey flickers");
  await card(3).getByRole("button", { name: "Request regenerate" }).click();
  const flagged = page.locator("[data-test='clips-flagged'] [data-test='flagged-clip'][data-ordinal='3']");
  await expect(flagged).toContainText("the jersey flickers");
  await card(3).locator("[data-test='clip-regenerate-clear'] button").click();
  await expect(flagged).toHaveCount(0);

  // Watch full video: a modal, built only when opened.
  const modal = page.locator("[data-test='watch-modal']");
  await expect(modal).toHaveCount(0);
  await page.locator("[data-test='watch-open']").click();
  await expect(modal).toBeVisible();
  const preview = modal.locator("[data-test='stitch-preview']");
  const marker = (n) => preview.locator(`[data-test='stitch-marker'][data-ordinal='${n}']`);
  await expect(preview.locator("[data-test='stitch-marker']")).toHaveCount(4);
  await expect(marker(2)).toHaveAttribute("data-from", "22500");
  await expect(marker(2)).toHaveAttribute("data-to", "42500");
  await expect(marker(2)).toHaveAttribute("data-source", "false");
  await expect(marker(2)).toContainText("version 1");
  await expect(preview.locator("[data-test='stitch-time']")).toContainText("0:00 / 1:12");
  await expect(preview.locator("[data-test='stitch-audio']")).toHaveAttribute("src", /source\/test_artist_a_tiled_demo\.mp4/);

  // Just before the first handover, clip 1 (no version) plays its source chunk.
  await preview.locator("[data-test='stitch-seek']").evaluate((el) => {
    el.value = "21500";
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await expect(preview).toHaveAttribute("data-chunk", "1");
  await expect(preview.locator("[data-test='stitch-now']")).toHaveText("Clip 1 · source");

  // Play: it crosses the handover by itself and clip 2's primary version takes the screen, muted.
  await preview.locator("[data-test='stitch-toggle']").click();
  await expect(preview).toHaveAttribute("data-playing", "true");
  await expect(preview).toHaveAttribute("data-chunk", "2", { timeout: 10_000 });
  await expect(preview.locator("[data-test='stitch-now']")).toHaveText("Clip 2 · version 1");
  const videos = await preview.locator("[data-test='stitch-video']").evaluateAll((list) => list.map((v) => ({
    src: v.getAttribute("src") || "", shown: getComputedStyle(v).opacity === "1", muted: v.muted,
  })));
  expect(videos.every((v) => v.muted)).toBe(true);
  expect(videos.find((v) => v.shown).src).toMatch(/clips\/tiled_demo_alt_\d\d_chunk_02_0020_0045_v01\.mp4/);

  // Closing the modal tears the player down.
  await modal.locator("[data-test='watch-close']").click();
  await expect(modal).toHaveCount(0);
});
