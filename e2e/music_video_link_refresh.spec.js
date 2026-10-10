// [e2e] The alt video page outlives its signed links. Every file on it is a
// signed URL good for fifteen minutes, and the operator leaves the page open
// far longer. A player that fails on a lapsed link asks the page's links
// endpoint for fresh ones, says so while it waits, comes back at the same place
// and plays; the other links on the page move over with it; and "This browser
// would not start both players" is never said about a lapsed link. The Watch
// full video modal does the same for its clips. A refresh the server refuses
// or leaves unanswered says which on the page and on the player (never "did
// not load" for a link that was never replaced). The timer ends with its page.
//
// HOW EXPIRY IS STAGED. Nothing here waits fifteen minutes. The page's own
// record of when its links were signed is wound back sixteen (lapse), which is
// what the passing of time does to it, and from then on the stand-in bucket
// answers 403 to every URL signed before that, as R2 does. The links endpoint
// is the real one. Its answer is passed through with a marker added to each URL
// (the fixture store signs the same URL every time, so without one a fresh link
// could not be told from a lapsed one), and one test holds it back to read
// what the page says while it waits. down makes it answer 503, as a server
// that is not answering does.
//
// HOW THE TIMER IS STAGED. The page's timer is armed to fire in a second
// (arm): its own schedule(), on a signing time wound back to a second short of
// the lapse. So the timer that fires is the page's real one, on a short fuse.
//
// WHAT THIS PROVES, AND WHAT IT DOES NOT. The players here really load and
// play: the bucket stand-in serves a small WebM (VP8), which CI's Chromium
// decodes; it may not decode the H.264 the pipeline makes, which is why the
// compare spec next door stands in for play(). So the failure, the fetch, the
// swap, the reload at the kept place and the playback are real. The first test
// stages a failure on a paused player by firing its error event, because a real
// refetch would itself reset the place the test is about to measure; the tests
// after it fail the players for real, on a 403. Not proven: that R2 answers a
// lapsed link the way the stand-in does, and the timer's fourteen-minute
// length (it is armed short, or its handler is called directly). Wholly
// synthetic data: the stitch demo and the lettered demo seeded by e2e/seed.rb.
const path = require("path");
const fs = require("fs");
const { test, expect } = require("@playwright/test");

const WEBM = fs.readFileSync(path.join(__dirname, "..", "test", "fixtures", "files", "link_refresh_demo.webm"));
const STITCH_DEMO = "/music_videos/test-artist-a-stitch-demo/alt_videos/1";
const LETTERED_DEMO = "/music_videos/test-artist-b-lettered-demo/alt_videos/1";

// The stand-in bucket and the passed-through links endpoint for one page.
// lapse(): time passes; every link signed so far stops opening.
// hold() / release(): keep the next links answer back, then let it go.
const stage = async (page) => {
  const state = { round: 0, lapsed: new Set(), asked: 0, held: null, open: null, down: false };
  const roundOf = (url) => Number((url.match(/[?&]fresh=(\d+)/) || [])[1] || 0);

  await page.route("https://fixture.invalid/**", (route) => {
    if (state.lapsed.has(roundOf(route.request().url()))) return route.fulfill({ status: 403, contentType: "text/plain", body: "Request has expired" });
    // Byte ranges, as a bucket serves them: without them Chromium cannot seek the file.
    const range = /bytes=(\d+)-(\d*)/.exec(route.request().headers().range || "");
    if (!range) return route.fulfill({ status: 200, contentType: "video/webm", headers: { "Accept-Ranges": "bytes" }, body: WEBM });
    const from = Number(range[1]), to = range[2] ? Math.min(Number(range[2]), WEBM.length - 1) : WEBM.length - 1;
    return route.fulfill({ status: 206, contentType: "video/webm", body: WEBM.subarray(from, to + 1),
                           headers: { "Accept-Ranges": "bytes", "Content-Range": `bytes ${from}-${to}/${WEBM.length}` } });
  });
  await page.route("**/alt_videos/1/links", async (route) => {
    state.asked += 1;
    if (state.held) await state.held;
    if (state.down) return route.fulfill({ status: 503, contentType: "text/plain", body: "" });
    const response = await route.fetch();
    if (!response.ok()) return route.fulfill({ response });
    const body = await response.json();
    state.round += 1;
    for (const map of [body.inline, body.download]) {
      for (const key of Object.keys(map)) map[key] += `&fresh=${state.round}`;
    }
    return route.fulfill({ response, json: body });
  });

  return {
    state,
    lapse: async () => {
      state.lapsed.add(state.round);
      await page.evaluate(() => { window.signedLinks.signedAt -= 16 * 60 * 1000; });
    },
    hold: () => { state.held = new Promise((resolve) => { state.open = resolve; }); },
    // The page's own timer, due in `ms`: the links lapse then, and it fires.
    arm: (ms = 1000) => page.evaluate((due) => {
      const links = window.signedLinks;
      links.signedAt = Date.now() - links.ttlMs + links.LEAD_MS + due;
      links.schedule();
    }, ms),
    release: () => { state.open(); state.held = null; },
  };
};

const media = (scope) => scope.locator("video").evaluateAll((videos) => videos.map((v) => ({
  test: v.dataset.test, ready: v.readyState, paused: v.paused, at: v.currentTime, src: v.currentSrc || v.src, failed: !!v.error,
})));
const loaded = (scope) => expect.poll(async () => (await media(scope)).map((v) => v.ready >= 1 && !v.failed)).not.toContain(false);

test("a player on a lapsed link gets a fresh one, keeps its place and plays; nothing blames the browser", async ({ page }) => {
  const bucket = await stage(page);
  await page.goto(STITCH_DEMO);

  const card = page.locator("[data-test='alt-clip'][data-ordinal='1']");
  const compare = card.locator("[data-test='clip-compare']");
  const button = compare.locator("[data-test='clip-play-both']");
  const waiting = compare.locator("[data-test='clip-link-refreshing'], [data-test='clip-version-link-refreshing']");
  const failed = compare.locator("[data-test='clip-load-failed'], [data-test='clip-version-load-failed']");
  const blocked = compare.locator("[data-test='clip-play-both-blocked']");
  const banner = page.locator("[data-test='links-status']");
  await loaded(compare);

  // Play both for a second, then pause: both players now hold a place worth keeping.
  await button.click();
  await expect(compare).toHaveAttribute("data-state", "playing");
  await expect.poll(async () => Math.min(...(await media(compare)).map((v) => v.at))).toBeGreaterThan(1);
  await button.click();
  await expect(compare).toHaveAttribute("data-state", "paused");
  const place = (await media(compare)).map((v) => v.at);

  // The links lapse and both players fail, as a player does when it reaches
  // for more of a file its link no longer opens.
  await bucket.lapse();
  bucket.hold();
  await compare.locator("video").evaluateAll((videos) => videos.forEach((v) => v.dispatchEvent(new Event("error"))));

  // While the fresh links are on their way, the page says exactly that.
  await expect(waiting).toHaveCount(2);
  await expect(waiting.first()).toBeVisible();
  await expect(waiting.last()).toBeVisible();
  await expect(waiting.first()).toHaveText("This link expired: getting a fresh one…");
  await expect(failed.first()).toBeHidden();
  await expect(failed.last()).toBeHidden();
  await expect(blocked).toBeHidden();
  await expect(banner).toBeHidden();

  bucket.release();
  await expect(waiting.first()).toBeHidden();
  await expect(waiting.last()).toBeHidden();
  await expect(compare.locator("[data-test='clip-player']")).toHaveAttribute("src", /stitch_demo_chunk_01_.*&fresh=1#t=[\d.]+$/);
  await expect(compare.locator("[data-test='clip-version-player']")).toHaveAttribute("src", /_v\d\d\.mp4.*&fresh=1#t=[\d.]+$/);
  await loaded(compare);
  // Each player is back where it was, still paused, with nothing reported.
  await expect.poll(async () => (await media(compare)).map((v) => Math.abs(v.at - place[(v.test === "clip-player") ? 0 : 1]) < 0.15)).toEqual([true, true]);
  expect((await media(compare)).map((v) => v.paused)).toEqual([true, true]);
  await expect(compare).toHaveAttribute("data-state", "paused");
  await expect(failed.first()).toBeHidden();
  await expect(failed.last()).toBeHidden();
  // One request served both players, and the page's other links moved with them.
  expect(bucket.state.asked).toBe(1);
  await expect(card.locator("[data-test='clip-version-open']").first()).toHaveAttribute("href", /&fresh=1$/);
  await expect(card.locator("[data-test='clip-chunk-download']")).toHaveAttribute("href", /response-content-disposition=attachment.*&fresh=1$/);

  // The links lapse again. This time the players fail for real (the bucket
  // refuses them) and the operator presses Play both before the fresh links land.
  await bucket.lapse();
  bucket.hold();
  await compare.locator("video").evaluateAll((videos) => videos.forEach((v) => v.load()));
  await expect(waiting.first()).toBeVisible();
  await expect(waiting.last()).toBeVisible();
  expect((await media(compare)).map((v) => v.failed)).toEqual([true, true]);
  await button.click();
  // The players could not start, and the reason given is the lapsed link, not the browser.
  await expect(waiting.first()).toBeVisible();
  await expect(blocked).toBeHidden();
  await expect(failed.first()).toBeHidden();
  await expect(failed.last()).toBeHidden();

  bucket.release();
  // The play that was asked for goes ahead on the fresh links.
  await expect(compare).toHaveAttribute("data-state", "playing");
  await expect(compare.locator("[data-test='clip-version-player']")).toHaveAttribute("src", /&fresh=2(#t=[\d.]+)?$/);
  await expect.poll(async () => (await media(compare)).map((v) => !v.paused && !v.failed && v.at > 0.2)).toEqual([true, true]);
  await expect(waiting.first()).toBeHidden();
  await expect(waiting.last()).toBeHidden();
  await expect(blocked).toBeHidden();
  await expect(failed.first()).toBeHidden();
  await expect(failed.last()).toBeHidden();
  await expect(banner).toBeHidden();
  expect(bucket.state.asked).toBe(2);
});

test("a single preview whose link lapsed is refreshed and plays; a file missing on a fresh link says so", async ({ page }) => {
  const bucket = await stage(page);
  await page.goto(LETTERED_DEMO);

  const solo = page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-solo']");
  const waiting = solo.locator("[data-test='clip-link-refreshing']");
  const failed = solo.locator("[data-test='clip-load-failed']");
  await loaded(solo);

  await bucket.lapse();
  bucket.hold();
  await solo.locator("video").evaluate((v) => v.load());
  await expect(waiting).toBeVisible();
  await expect(failed).toBeHidden();
  await page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-preview-button']").click();

  bucket.release();
  await expect(waiting).toBeHidden();
  await expect.poll(async () => (await media(solo)).map((v) => !v.paused && !v.failed && v.at > 0.2)).toEqual([true]);
  await expect(failed).toBeHidden();
  expect(bucket.state.asked).toBe(1);

  // The fresh link itself stops opening while the page still counts it fresh:
  // that is a missing file, reported as one, with no second request.
  bucket.state.lapsed.add(bucket.state.round);
  await solo.locator("video").evaluate((v) => v.load());
  await expect(failed).toBeVisible();
  await expect(failed).toHaveText(/^The source chunk did not load: /);
  await expect(waiting).toBeHidden();
  expect(bucket.state.asked).toBe(1);
});

test("the links are refreshed before anything fails, one request at a time", async ({ page }) => {
  const bucket = await stage(page);
  await page.goto(LETTERED_DEMO);

  const card = page.locator("[data-test='alt-clip'][data-ordinal='3']");
  await loaded(page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-solo']"));
  await expect(card.locator("[data-test='clip-frame']")).toHaveCount(2);

  // Fresh links: the timer's handler has nothing to do. A request it had made
  // would be in flight, and said, the moment it returns (refresh() does both
  // before it yields), so that is read first, in the page; then one that had
  // been sent is given time to arrive.
  const idle = await page.evaluate(() => {
    window.signedLinks.woke();
    return { asking: window.signedLinks.inFlight !== null, said: window.signedLinks.state };
  });
  expect(idle).toEqual({ asking: false, said: "" });
  await page.waitForTimeout(500);
  expect(bucket.state.asked).toBe(0);

  // Lapsed: what the timer and the tab's return both call, called three times at once.
  await bucket.lapse();
  await page.evaluate(() => { window.signedLinks.woke(); window.signedLinks.woke(); window.signedLinks.refresh(); });

  await expect(card.locator("[data-test='clip-frame-download']").first()).toHaveAttribute("href", /response-content-disposition=attachment.*&fresh=1$/);
  await expect(card.locator("[data-test='clip-frame'] a[target='_blank']").first()).toHaveAttribute("href", /_ref_\d+\.\w+\?.*&fresh=1$/);
  await expect(card.locator("[data-test='clip-chunk-download']")).toHaveAttribute("href", /&fresh=1$/);
  await expect(page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-player']")).toHaveAttribute("src", /&fresh=1#t=0\.001$/);
  expect(bucket.state.asked).toBe(1);
  expect(await page.evaluate(() => window.signedLinks.fresh())).toBe(true);
  await expect(page.locator("[data-test='clip-load-failed']:visible")).toHaveCount(0);
  await expect(page.locator("[data-test='links-status']")).toBeHidden();
});

test("Watch full video opens on the freshest links, and a clip that fails mid-watch is cued again on a fresh one", async ({ page }) => {
  const bucket = await stage(page);
  await page.goto(STITCH_DEMO);
  await loaded(page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-compare']"));

  // The page sat open: its links lapsed and were refreshed before the modal was ever built.
  await bucket.lapse();
  await page.evaluate(() => window.signedLinks.woke());
  await expect.poll(() => bucket.state.round).toBe(1);
  await expect.poll(() => page.evaluate(() => window.signedLinks.fresh())).toBe(true);

  await page.locator("[data-test='watch-open']").click();
  const preview = page.locator("[data-test='stitch-preview']");
  const front = preview.locator("[data-test='stitch-video']").first();
  const waiting = preview.locator("[data-test='stitch-link-refreshing']");
  const failed = preview.locator("[data-test='stitch-load-failed']");
  // Built from the page as rendered, yet on the refreshed links: the clip and the source audio.
  await expect(front).toHaveAttribute("src", /&fresh=1$/);
  await expect(preview.locator("[data-test='stitch-audio']")).toHaveAttribute("src", /&fresh=1$/);
  await expect.poll(() => front.evaluate((v) => v.readyState >= 1 && !v.error)).toBe(true);

  // Mid-watch the links lapse and the clip on screen fails.
  await bucket.lapse();
  bucket.hold();
  await front.evaluate((v) => v.load());
  await expect(waiting).toBeVisible();
  await expect(waiting).toHaveText("This link expired: getting a fresh one…");
  await expect(failed).toBeHidden();

  bucket.release();
  await expect(front).toHaveAttribute("src", /&fresh=2$/);
  await expect.poll(() => front.evaluate((v) => v.readyState >= 1 && !v.error)).toBe(true);
  await expect(waiting).toBeHidden();
  await expect(failed).toBeHidden();
  expect(bucket.state.asked).toBe(2);
});

test("after a Turbo visit away, the page's timer makes no request", async ({ page }) => {
  const bucket = await stage(page);
  await page.goto(LETTERED_DEMO);
  await loaded(page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-solo']"));

  // THE CONTROL: left on the page, the armed timer fires and asks, once.
  await bucket.arm();
  await expect.poll(() => bucket.state.asked).toBe(1);
  await expect.poll(() => page.evaluate(() => window.signedLinks.fresh())).toBe(true);

  // Armed again, and this time the operator follows a link to a page with no
  // signed links before it fires. Turbo swaps the body and keeps the window.
  await page.evaluate(() => {
    window.__sameWindow = true;
    document.body.insertAdjacentHTML("beforeend", "<a id='away' href='/admin/links' style='position:fixed;top:0;left:0;z-index:99999'>away</a>");
  });
  await bucket.arm();
  await page.locator("#away").click();
  await expect(page).toHaveURL(/\/admin\/links$/);
  await expect(page.locator("[data-links-url]")).toHaveCount(0);
  expect(await page.evaluate(() => window.__sameWindow)).toBe(true);

  // Past the moment the timer was due: nothing was asked, and nothing is left to ask.
  await page.waitForTimeout(2500);
  expect(bucket.state.asked).toBe(1);
  expect(await page.evaluate(() => ({ url: window.signedLinks.url, timer: window.signedLinks.timer }))).toEqual({ url: null, timer: null });
  // Coming back to the tab is the other thing that asks: it does not either.
  await page.evaluate(() => { document.dispatchEvent(new Event("visibilitychange")); window.dispatchEvent(new Event("pageshow")); });
  await page.waitForTimeout(500);
  expect(bucket.state.asked).toBe(1);

  // Back on the page (a Turbo visit again), its links are kept fresh as before.
  await page.goBack();
  await expect(page.locator("[data-links-url]")).toHaveCount(1);
  await expect.poll(() => page.evaluate(() => window.signedLinks.url)).toMatch(/\/alt_videos\/1\/links$/);
  await bucket.arm();
  await expect.poll(() => bucket.state.asked).toBe(2);
});

test("a timer that fires after its page's links element is gone stops, with no request", async ({ page }) => {
  const bucket = await stage(page);
  await page.goto(LETTERED_DEMO);
  await loaded(page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-solo']"));

  // The body is replaced without Turbo's render event (so nothing has stopped
  // the timer), as any script that swaps the page would.
  await bucket.arm();
  await page.evaluate(() => { document.querySelector("[data-links-url]").remove(); });
  expect(await page.evaluate(() => window.signedLinks.timer !== null)).toBe(true);

  await expect.poll(() => page.evaluate(() => window.signedLinks.url), { timeout: 5000 }).toBeNull();
  await page.waitForTimeout(500);
  expect(bucket.state.asked).toBe(0);
});

test("a refresh the server refuses says the session ended, on the page and on the player, and clears once signed in again", async ({ page }) => {
  await page.setViewportSize({ width: 390, height: 844 });
  const bucket = await stage(page);
  await page.goto(LETTERED_DEMO);

  const solo = page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-solo']");
  const failed = solo.locator("[data-test='clip-load-failed']");
  const expired = solo.locator("[data-test='clip-link-expired']");
  const banner = page.locator("[data-test='links-status']");
  const spacer = page.locator("[data-test='links-status-spacer']");
  await loaded(solo);
  await expect(banner).toBeHidden();
  await expect(spacer).toBeHidden();

  // The session ends while the page sits open: the real endpoint answers 401.
  const session = await page.context().cookies();
  await page.context().clearCookies();
  await bucket.lapse();
  await solo.locator("video").evaluate((v) => v.load());

  await expect(banner).toBeVisible();
  await expect(banner).toHaveAttribute("data-state", "signin");
  await expect(banner.locator("[data-test='links-status-signin']")).toHaveText(/expired, and so did your session\.\s+Sign in again\s+in a new tab, then come back to this one\./);
  await expect(banner.locator("[data-test='links-status-failed']")).toBeHidden();
  // Signing in happens in another tab, so this page keeps its place. This state has no close.
  const signIn = banner.locator("[data-test='links-status-signin-link']");
  await expect(signIn).toHaveAttribute("target", "_blank");
  await expect(signIn).toHaveAttribute("href", "/login");
  await expect(banner.locator("[data-test='links-status-close']")).toBeHidden();
  // The player had no fresh link to fail on, and does not say it did.
  await expect(expired).toBeVisible();
  await expect(expired).toHaveText("This link expired, and your session ended: sign in again.");
  await expect(failed).toBeHidden();
  await expect(solo.locator("[data-test='clip-link-refreshing']")).toBeHidden();
  expect(bucket.state.asked).toBe(1);
  expect(bucket.state.round).toBe(0);

  // On a phone, scrolled to the end: the banner sits over the room made for
  // it, and over nothing the last clip offers to press.
  await page.evaluate(() => window.scrollTo(0, document.documentElement.scrollHeight));
  const fit = await page.evaluate(() => {
    const box = (el) => el.getBoundingClientRect();
    const bar = box(document.querySelector("[data-test='links-status']"));
    const room = box(document.querySelector("[data-test='links-status-spacer']"));
    const cards = document.querySelectorAll("[data-test='alt-clip']");
    const pressable = [...cards[cards.length - 1].querySelectorAll("button, a, input, summary")].map(box).filter((r) => r.width > 0 && r.height > 0);
    const under = pressable.filter((r) => r.bottom > bar.top && r.top < bar.bottom && r.right > bar.left && r.left < bar.right);
    return { pressable: pressable.length > 0, under: under.length, room: room.height >= bar.height + 16, wide: bar.right <= window.innerWidth && bar.left >= 0 };
  });
  expect(fit).toEqual({ pressable: true, under: 0, room: true, wide: true });

  // Signed in again (in the other tab) and back on this one: the page asks
  // again, the banner and its room go, and the player loads on the fresh link.
  await page.context().addCookies(session);
  await page.evaluate(() => document.dispatchEvent(new Event("visibilitychange")));
  await expect(banner).toBeHidden();
  await expect(spacer).toBeHidden();
  await expect(solo.locator("[data-test='clip-player']")).toHaveAttribute("src", /&fresh=1/);
  await loaded(solo);
  await expect(expired).toBeHidden();
  await expect(failed).toBeHidden();
  expect(bucket.state.asked).toBe(2);
});

test("a refresh that goes unanswered says so, can be closed, and says so again the next time", async ({ page }) => {
  const bucket = await stage(page);
  await page.goto(STITCH_DEMO);

  const compare = page.locator("[data-test='alt-clip'][data-ordinal='1'] [data-test='clip-compare']");
  const banner = page.locator("[data-test='links-status']");
  const spacer = page.locator("[data-test='links-status-spacer']");
  const close = banner.locator("[data-test='links-status-close']");
  const expired = compare.locator("[data-test='clip-link-expired'], [data-test='clip-version-link-expired']");
  const failed = compare.locator("[data-test='clip-load-failed'], [data-test='clip-version-load-failed']");
  await loaded(compare);

  bucket.state.down = true;
  await bucket.lapse();
  await compare.locator("video").evaluateAll((videos) => videos.forEach((v) => v.load()));

  await expect(banner).toBeVisible();
  await expect(banner).toHaveAttribute("data-state", "failed");
  await expect(banner.locator("[data-test='links-status-failed']")).toContainText("fresh ones could not be fetched");
  await expect(spacer).toBeVisible();
  await expect(expired).toHaveCount(2);
  await expect(expired.first()).toHaveText("This link expired, and a fresh one could not be fetched.");
  await expect(expired.last()).toBeVisible();
  await expect(failed.first()).toBeHidden();
  await expect(failed.last()).toBeHidden();

  // Closed: the banner and the room it took both go.
  await close.click();
  await expect(banner).toBeHidden();
  await expect(spacer).toBeHidden();

  // The next refresh that fails says so again.
  const before = bucket.state.asked;
  await compare.locator("video").first().evaluate((v) => v.load());
  await expect(banner).toBeVisible();
  expect(bucket.state.asked).toBe(before + 1);

  // Watch full video, opened with the server still not answering: the clip on
  // screen says its link expired, not that its file failed on a fresh one.
  await page.locator("[data-test='watch-open']").click();
  const preview = page.locator("[data-test='stitch-preview']");
  const front = preview.locator("[data-test='stitch-video']").first();
  await expect(preview.locator("[data-test='stitch-link-expired']")).toBeVisible();
  await expect(preview.locator("[data-test='stitch-link-expired']")).toHaveText("This link expired, and a fresh one could not be fetched.");
  await expect(preview.locator("[data-test='stitch-load-failed']")).toBeHidden();

  // The server answers again: everything moves onto the fresh links and says nothing.
  bucket.state.down = false;
  await page.evaluate(() => window.signedLinks.woke());
  await expect(banner).toBeHidden();
  await expect(front).toHaveAttribute("src", /&fresh=1$/);
  await expect.poll(() => front.evaluate((v) => v.readyState >= 1 && !v.error)).toBe(true);
  await expect(preview.locator("[data-test='stitch-link-expired']")).toBeHidden();
  await expect(preview.locator("[data-test='stitch-load-failed']")).toBeHidden();
  await loaded(compare);
  await expect(expired.first()).toBeHidden();
  await expect(expired.last()).toBeHidden();
});
