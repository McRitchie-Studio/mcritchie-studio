// [e2e] The recast round trip on a tiled video: the operator takes a chunk's
// hand-off, uploads the generated MP4 back as a take, flags another chunk for a
// regenerate, and plays the stitch preview across a handover. Wholly synthetic
// data, seeded by e2e/seed.rb from db/seeds/data/tiled_video.rb. No bucket is
// reached: the upload is dropped by the lane's stand-in store, and every signed
// URL (fixture.invalid) is answered here with one small test-pattern MP4.
//
// The lane's Chromium may not decode H.264, so nothing here reads a video's own
// clock. The preview then runs on its timer instead of the source audio, which
// is the same path a video with unreachable audio takes.
const path = require("path");
const fs = require("fs");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const MP4 = path.join(__dirname, "..", "test", "fixtures", "files", "stitch_demo.mp4");

test("the operator uploads a take, flags a chunk and plays the stitched preview", async ({ page }) => {
  const body = fs.readFileSync(MP4);
  await page.route("https://fixture.invalid/**", (route) => route.fulfill({ status: 200, contentType: "video/mp4", body }));
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-artist-a-tiled-demo");

  const preview = page.locator("[data-test='stitch-preview']");
  const marker = (n) => preview.locator(`[data-test='stitch-marker'][data-ordinal='${n}']`);
  const row = (n) => page.locator(`[data-test='chunk-row'][data-ordinal='${n}']`);

  // One player for the whole video: four chunks, each handing over mid-overlap.
  await expect(preview.locator("[data-test='stitch-marker']")).toHaveCount(4);
  await expect(marker(2)).toHaveAttribute("data-from", "22500");
  await expect(marker(2)).toHaveAttribute("data-to", "42500");
  await expect(preview.locator("[data-test='stitch-time']")).toContainText("0:00 / 1:12");
  await expect(preview.locator("[data-test='stitch-audio']")).toHaveAttribute("src", /source\/test_artist_a_tiled_demo\.mp4/);

  // Hand-off: the source chunk downloads as a file, beside the prompt and the look line.
  const handoff = row(2).locator("[data-test='chunk-handoff']");
  const download = handoff.locator("[data-test='chunk-source-download']");
  await expect(download).toHaveAttribute("download", "tiled_demo_chunk_02_0020_0045.mp4");
  await expect(download).toHaveAttribute("href", /chunks\/tiled_demo_chunk_02_0020_0045\.mp4.*response-content-disposition=attachment/);
  await expect(row(2).locator("[data-test='chunk-prompt']")).toContainText("Replace the man in the red jacket");
  await expect(handoff.locator("[data-test='chunk-look-none']")).toBeVisible();

  // Upload the generated MP4 for chunk 2: it becomes that chunk's newest take, current.
  const before = await row(2).locator("[data-test='chunk-take']").count();
  await row(2).locator("[data-test='chunk-take-file']").setInputFiles(MP4);
  await row(2).locator("[data-test='chunk-take-submit']").click();
  await expect(row(2).locator("[data-test='chunk-take']")).toHaveCount(before + 1);
  const take = await row(2).getAttribute("data-take");
  expect(Number(take)).toBeGreaterThan(0);
  await expect(row(2).locator("[data-test='chunk-take-state']")).toHaveText(`Take ${take} current`);
  await expect(row(2).locator(`[data-test='chunk-take'][data-number='${take}']`)).toHaveAttribute("data-current", "true");
  await expect(row(2).locator(`[data-test='chunk-take'][data-number='${take}']`))
    .toHaveAttribute("data-key", new RegExp(`generated/tiled_demo_chunk_02_0020_0045_take_0?${take}\\.mp4$`));
  await expect(marker(2)).toHaveAttribute("data-source", "false");
  await expect(marker(2)).toContainText(`take ${take}`);

  // Request a regenerate on chunk 3: it joins the flagged list with its note, then clears.
  await row(3).locator("[data-test='chunk-regenerate-input']").fill("the jersey flickers");
  await row(3).getByRole("button", { name: "Request regenerate" }).click();
  const flagged = page.locator("[data-test='chunks-flagged'] [data-test='flagged-chunk'][data-ordinal='3']");
  await expect(flagged).toContainText("Chunk 3");
  await expect(flagged).toContainText("the jersey flickers");
  await expect(row(3)).toHaveAttribute("data-flagged", "true");
  await expect(marker(3)).toHaveAttribute("data-flagged", "true");
  await expect(page.locator("[data-test='stitch-ready']")).toHaveText("Not ready to stitch");
  await row(3).locator("[data-test='chunk-regenerate-clear'] button").click();
  await expect(flagged).toHaveCount(0);
  await expect(row(3)).toHaveAttribute("data-flagged", "false");

  // Seek to just before the first handover (22.5 s): chunk 1 is on screen, its source cut.
  await expect(preview).toHaveAttribute("data-chunk", "1");
  await preview.locator("[data-test='stitch-seek']").evaluate((el) => {
    el.value = "21500";
    el.dispatchEvent(new Event("input", { bubbles: true }));
  });
  await expect(preview.locator("[data-test='stitch-time']")).toContainText("0:21 / 1:12");
  await expect(preview).toHaveAttribute("data-chunk", "1");
  await expect(preview).toHaveAttribute("data-source", "true");
  await expect(preview.locator("[data-test='stitch-now']")).toHaveText("Chunk 1 · source");
  // The next chunk's take is already loaded into the standby video.
  const sources = () => preview.locator("[data-test='stitch-video']").evaluateAll((videos) => videos.map((v) => ({
    src: v.getAttribute("src") || "", shown: getComputedStyle(v).opacity === "1", muted: v.muted,
  })));
  await expect.poll(async () => (await sources()).find((v) => !v.shown).src).toMatch(/generated\/tiled_demo_chunk_02_0020_0045_take_/);

  // Play: the preview crosses the handover on its own and chunk 2's take takes the screen, muted.
  await preview.locator("[data-test='stitch-toggle']").click();
  await expect(preview).toHaveAttribute("data-playing", "true");
  await expect(preview).toHaveAttribute("data-chunk", "2", { timeout: 10_000 });
  await expect(preview).toHaveAttribute("data-source", "false");
  await expect(preview.locator("[data-test='stitch-now']")).toHaveText(`Chunk 2 · take ${take}`);
  await expect(marker(2)).toHaveAttribute("aria-current", "true");
  await expect(marker(1)).toHaveAttribute("aria-current", "false");
  const playing = await sources();
  expect(playing.every((v) => v.muted)).toBe(true);
  expect(playing.find((v) => v.shown).src).toMatch(/generated\/tiled_demo_chunk_02_0020_0045_take_/);
  expect(playing.find((v) => !v.shown).src).toMatch(/chunks\/tiled_demo_chunk_03_0040_0105\.mp4/);
  await preview.locator("[data-test='stitch-toggle']").click();
  await expect(preview).toHaveAttribute("data-playing", "false");

  // A chunk with no take falls back to its source cut, marked as source.
  await marker(4).click();
  await expect(preview).toHaveAttribute("data-chunk", "4");
  await expect(preview).toHaveAttribute("data-source", "true");
  await expect(preview.locator("[data-test='stitch-now']")).toHaveText("Chunk 4 · source");
  await expect(preview.locator("[data-test='stitch-time']")).toContainText("1:02 / 1:12");
});
