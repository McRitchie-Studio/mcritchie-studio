// [e2e] Side-by-side compare on an alt video clip (recast pipeline, piece 18):
// a clip with a primary version shows the source chunk ("Original") beside
// that version; Play both starts the two together from the start with the
// ORIGINAL muted, so the only sound is the version's; pausing either pauses
// both, and playing either plays both. A clip with no version keeps the single
// preview, whose button plays the source chunk with its sound.
//
// WHAT THIS PROVES, AND WHAT IT DOES NOT. CI's Chromium may not decode H.264,
// so the media element's play() and pause() are replaced (before any page
// script runs) by stand-ins that keep a playing flag and fire the same "play"
// and "pause" events a real element fires. Everything above that seam is real:
// the button, clipPair()'s state machine, which elements it starts, stops and
// mutes, and how one player's event moves the other. What it does not prove:
// that a frame is painted (the posters are judged by eye in the screenshots),
// that two decoding videos stay within a frame (the drift loop needs a real
// clock; it was measured by hand in Chrome), or the shared scrub (disabled
// until the browser reads a duration). Wholly synthetic data: the stitch demo
// seeded by e2e/seed.rb (db/seeds/data/stitch_ready_video.rb), whose clip 1
// always has a primary version.
const path = require("path");
const fs = require("fs");
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const MP4 = path.join(__dirname, "..", "test", "fixtures", "files", "stitch_demo.mp4");

// A media element that "plays" without decoding: a flag, and the real events.
const standInPlayer = () => {
  const proto = HTMLMediaElement.prototype;
  Object.defineProperty(proto, "paused", { configurable: true, get() { return !this.__playing; } });
  proto.play = function () {
    if (!this.__playing) {
      this.__playing = true;
      this.__plays = (this.__plays || 0) + 1;
      this.dispatchEvent(new Event("play"));
    }
    return Promise.resolve();
  };
  proto.pause = function () {
    if (this.__playing) {
      this.__playing = false;
      this.dispatchEvent(new Event("pause"));
    }
  };
};

// What each player is doing: playing, muted, and how many times it was started.
const players = (scope) => scope.locator("video").evaluateAll((videos) =>
  videos.map((v) => ({ test: v.dataset.test, playing: !!v.__playing, muted: v.muted, plays: v.__plays || 0, at: v.currentTime })));

test("Play both runs the primary beside the original, sound from the version only", async ({ page }) => {
  const body = fs.readFileSync(MP4);
  await page.route("https://fixture.invalid/**", (route) => route.fulfill({ status: 200, contentType: "video/mp4", body }));
  await page.addInitScript(standInPlayer);
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-artist-a-stitch-demo/alt_videos/1");

  const card = page.locator("[data-test='alt-clip'][data-ordinal='1']");
  const compare = card.locator("[data-test='clip-compare']");
  const primary = await card.getAttribute("data-primary");
  await expect(card).toHaveAttribute("data-compare", "true");
  await expect(compare.locator("[data-test='clip-compare-original'] figcaption")).toHaveText("Original");
  await expect(compare.locator("[data-test='clip-compare-version'] figcaption")).toHaveText(`Version ${primary} (primary)`);

  // Both open on a first-frame src and nothing plays until asked.
  await expect(compare.locator("[data-test='clip-player']")).toHaveAttribute("src", /stitch_demo_chunk_01_.*#t=0\.001$/);
  await expect(compare.locator("[data-test='clip-version-player']")).toHaveAttribute("src", new RegExp(`_v${primary.padStart(2, "0")}\\.mp4.*#t=0\\.001$`));
  await expect(compare).toHaveAttribute("data-state", "idle");
  expect((await players(compare)).filter((p) => p.playing)).toEqual([]);

  // Play both: both start from 0, the original muted, the version the one sound.
  const button = compare.locator("[data-test='clip-play-both']");
  await button.click();
  await expect(compare).toHaveAttribute("data-state", "playing");
  await expect(button).toHaveText("Pause both");
  let state = await players(compare);
  expect(state).toEqual([
    expect.objectContaining({ test: "clip-player", playing: true, muted: true, plays: 1 }),
    expect.objectContaining({ test: "clip-version-player", playing: true, muted: false, plays: 1 }),
  ]);
  expect(state.filter((p) => p.playing && !p.muted).map((p) => p.test)).toEqual(["clip-version-player"]);
  for (const p of state) expect(p.at).toBeLessThan(0.01);

  // Pausing one (its own control) pauses the other.
  await compare.locator("[data-test='clip-version-player']").evaluate((v) => v.pause());
  await expect(compare).toHaveAttribute("data-state", "paused");
  await expect(button).toHaveText("Resume both");
  expect((await players(compare)).map((p) => p.playing)).toEqual([false, false]);

  // Playing the other (its own control) brings both back, still one sound.
  await compare.locator("[data-test='clip-player']").evaluate((v) => v.play());
  await expect(compare).toHaveAttribute("data-state", "playing");
  state = await players(compare);
  expect(state.map((p) => [p.playing, p.muted])).toEqual([[true, true], [true, false]]);

  // Pause both, then From the start: both restart together.
  await button.click();
  await expect(compare).toHaveAttribute("data-state", "paused");
  expect((await players(compare)).map((p) => p.playing)).toEqual([false, false]);
  // Seeking one with its own control moves the other. A seek the pair makes
  // itself (the drift fix on the muted original) must NOT move the version:
  // that would drag the only sound along (a bug found measuring real Chrome).
  const times = () => compare.locator("video").evaluateAll((vs) => vs.map((v) => Math.round(v.currentTime * 1000) / 1000));
  await compare.evaluate((root) => {
    const original = root.querySelector("[data-test='clip-player']");
    original.currentTime = 3;
    original.dispatchEvent(new Event("seeking"));
  });
  await expect.poll(times).toEqual([3, 3]);
  await compare.evaluate((root) => {
    const original = root.querySelector("[data-test='clip-player']");
    window.Alpine.$data(root).seekTo(original, 7);
    original.dispatchEvent(new Event("seeking"));
  });
  await expect.poll(times).toEqual([7, 3]);

  await compare.locator("[data-test='clip-play-both-restart']").click();
  await expect(compare).toHaveAttribute("data-state", "playing");
  state = await players(compare);
  expect(state.map((p) => [p.playing, p.muted])).toEqual([[true, true], [true, false]]);
  for (const p of state) expect(p.at).toBeLessThan(0.01);
});

test("a clip with no version keeps the single preview, which plays the source with its sound", async ({ page }) => {
  await page.route("https://fixture.invalid/**", (route) => route.fulfill({ status: 200, contentType: "video/mp4", body: fs.readFileSync(MP4) }));
  await page.addInitScript(standInPlayer);
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/music_videos/test-artist-b-lettered-demo/alt_videos/1");

  const card = page.locator("[data-test='alt-clip'][data-ordinal='1']");
  await expect(card).toHaveAttribute("data-compare", "false");
  await expect(card.locator("[data-test='clip-compare']")).toHaveCount(0);
  const player = card.locator("[data-test='clip-player']");
  // Visible before anything is pressed: it holds the first frame, not a black box.
  await expect(player).toBeVisible();
  await expect(player).toHaveAttribute("preload", "metadata");
  await expect(player).toHaveAttribute("src", /#t=0\.001$/);

  await card.locator("[data-test='clip-preview-button']").click();
  await expect(card.locator("[data-test='clip-preview-button']")).toBeHidden();
  expect(await players(card.locator("[data-test='clip-solo']"))).toEqual([
    expect.objectContaining({ test: "clip-player", playing: true, muted: false, plays: 1 }),
  ]);
});
