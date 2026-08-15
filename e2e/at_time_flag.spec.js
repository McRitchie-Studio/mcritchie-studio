const { test, expect } = require("@playwright/test");

// [e2e] The "at" format's CLIENT half — the only half a server test can never see.
//
// WHY THIS FILE EXISTS. The flag is computed from
// `Intl.DateTimeFormat().resolvedOptions().timeZone`, and what broke was not our
// logic reading that value — it was WHICH value the engine hands back. Chromium
// and WebKit report the CLDR-canonical SHORT alias
// (America/Indiana/Indianapolis -> America/Indianapolis); Firefox reports the tzdb
// long form. The US list carried only the long form, so Chrome and Safari readers
// in Indianapolis and Louisville were shown the Americas globe — a foreign marker,
// inside the US, on the two largest affected metros — while a Firefox reader
// beside them saw the correct bare clock. No Ruby test can observe that: the
// canonicalization happens inside the browser's Intl, which is exactly what
// `timezoneId` on a real browser context exercises.
//
// It drives the REAL badge on the seeded Last Release (e2e/seed.rb ships one two
// minutes before the run), not injected markup — so the server half, the
// installed script, and the browser's own Intl are all in the loop, and a break in
// the markup contract between them fails here rather than passing on a fixture
// that agrees with itself.
//
// WHOSE SCRIPT THIS EXERCISES: studio-engine's. The hub's local fork was retired by
// /tasks/adopt-at-format-from-gem, so the layout renders `studio/at_time_script`
// and this is now the only browser-level coverage the primitive has in EITHER
// repo — the engine has no browser lane, and its consumer-CI runs this repo's Ruby
// suite only.
//
// AND WHAT IT STILL CANNOT SEE. playwright.config.js runs ONE project, Chromium.
// Every long-form id below canonicalizes to a short one before isUS() is handed
// anything, so the US_PREFIXES entries Firefox depends on are NEVER exercised here:
// delete them and this spec stays green. The Ruby backstop that does bite is
// test/integration/at_time_gem_adoption_test.rb, which asserts the membership
// property directly against the gem's list and runs in the engine's consumer-CI.
// Do not thin either one on the belief that the other covers it.
const BADGE = "#last-release [data-test='release-state-badge'] time[data-at-stamp]";

// Membership is the assertion: "" means the reader is inside the US and must see
// NO flag at all. Indiana and Kentucky are the regression, in both spellings;
// Midway is the territory that was wrong in every engine.
const ZONES = [
  ["America/Chicago", ""],
  ["America/Los_Angeles", ""],
  ["America/Indiana/Indianapolis", ""],
  ["America/Kentucky/Louisville", ""],
  ["America/Fort_Wayne", ""],
  ["Pacific/Honolulu", ""],
  ["Pacific/Midway", ""],
  ["America/Puerto_Rico", ""],
  ["Asia/Tokyo", "🇯🇵"],
  ["Europe/London", "🇬🇧"],
  ["America/Argentina/Buenos_Aires", "🇦🇷"],
  ["Australia/Sydney", "🇦🇺"],
  ["UTC", "🌐"],
];

async function readBadge(browser, timezoneId) {
  const context = await browser.newContext({ timezoneId });
  try {
    const page = await context.newPage();
    await page.goto("/deployments");

    const stamp = page.locator(BADGE);
    await expect(stamp).toBeVisible();
    // Hydration replaces the server's app-timezone fallback. Wait for the pass to
    // have run rather than racing it: the script stamps data-at-zone as it goes.
    await expect(stamp).toHaveAttribute("data-at-zone", /.+/);

    return await stamp.evaluate((el) => {
      const text = el.querySelector("[data-at-text]");
      const flag = el.querySelector("[data-at-flag]");
      const tRect = text.getBoundingClientRect();
      const fRect = flag.getBoundingClientRect();
      // WHICH SPELLING THIS ZONE SHOULD GET, decided from the STAMP, not from the
      // rendered text. data-at-epoch is the same input the script reads, and
      // toDateString() resolves in the browser's timezone — which is the viewer's
      // zone here, because the context was created with it. So this mirrors the
      // implementation's own branch (dateLabel: null when the stamp's local date
      // equals now's) without re-deriving the label, and the assertion below can
      // demand exactly one spelling instead of accepting either.
      const stamp = new Date(parseInt(el.dataset.atEpoch || "0", 10) * 1000);
      const sameLocalDay = stamp.toDateString() === new Date().toDateString();

      return {
        zone: el.dataset.atZone,
        clock: text.textContent,
        flag: flag.textContent,
        hidden: flag.hidden,
        title: el.title,
        sameLocalDay,
        gapPx: Math.round(fRect.left - tRect.right),
        rightOfClock: fRect.left >= tRect.right,
      };
    });
  } finally {
    await context.close();
  }
}

test("the flag marks the reader's country only outside the US, in every reported spelling of a US zone", async ({
  browser,
}) => {
  const wrong = [];

  for (const [timezoneId, expected] of ZONES) {
    const seen = await readBadge(browser, timezoneId);

    if (seen.flag !== expected) {
      // Report the zone the ENGINE reported, not the one we asked for — the gap
      // between those two IS the defect class.
      wrong.push(
        `${timezoneId} (engine reported ${seen.zone}): expected ${expected || "no flag"}, got ${seen.flag || "no flag"}`
      );
      continue;
    }

    // A US stamp must not merely hide the flag — it must reserve none of its space.
    expect(seen.hidden, `${timezoneId} flag slot hidden`).toBe(expected === "");

    if (expected !== "") {
      expect(seen.rightOfClock, `${timezoneId} flag sits right of the clock`).toBe(true);
      expect(seen.gapPx, `${timezoneId} flag gap`).toBeGreaterThanOrEqual(6);
    }

    // The clock is localized and prefixed, never the server fallback left in place.
    //
    // TWO LEGAL SPELLINGS, AND WHICH ONE IS NOT OPTIONAL. The seeded release is two
    // minutes old, so for most of the day every zone renders time-only. But a zone
    // far enough ahead crosses local midnight while UTC has not: at 15:01 UTC it is
    // already 00:01 in Asia/Tokyo, so a two-minute-old stamp is YESTERDAY to a Tokyo
    // reader and the badge correctly says "at Aug 15, 11:58p". A bare time-only
    // assertion therefore reds for about an hour a day, per far-ahead zone — it
    // blocked two unrelated PRs on 2026-08-15 before anyone read the message.
    //
    // The fix is NOT to accept either spelling, which would stop testing anything,
    // and NOT to pin the suite's timezone, which would hide the engine-vs-viewer
    // disagreement this file exists to catch. sameLocalDay is computed above from
    // the stamp itself, so this demands the ONE spelling that zone should get.
    //
    // The optional year covers the New Year's crossing (Dec 31 23:59 -> Jan 1
    // 00:01), where dateLabel appends it — a once-a-year bomb, and it would be
    // ironic to leave that one armed here of all places.
    // NOT named `expected` — that is the loop's flag expectation, destructured from
    // ZONES above, and a same-named const here shadows it into the temporal dead
    // zone so the flag comparison at the top of the body throws before it runs.
    const clockPattern = seen.sameLocalDay
      ? /^at \d{1,2}:\d{2}[ap]$/
      : /^at [A-Z][a-z]{2} \d{1,2}(?: \d{4})?, \d{1,2}:\d{2}[ap]$/;
    expect(
      seen.clock,
      `${timezoneId} clock (${seen.sameLocalDay ? "same local day" : "stamp is a previous local day"})`
    ).toMatch(clockPattern);
    // The relative read this format replaced still lives in the hover title.
    expect(seen.title, `${timezoneId} title`).toMatch(/ago ·/);
  }

  expect(wrong, `flag wrong in ${wrong.length} zone(s)`).toEqual([]);
});
