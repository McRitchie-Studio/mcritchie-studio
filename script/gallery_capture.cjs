// Capture a live app for the /build "Built with McRitchie Studio" gallery: a
// dark-mode still and a short motion loop the card plays on hover.
//
//   node script/gallery_capture.cjs <url> <slug> [--from <origin>]
//   node script/gallery_capture.cjs https://cyvasse.mcritchie.studio/play cyvasse
//
// Writes, under app/assets/images/build_gallery/:
//   <slug>.webp  the first screen at 1280x800 in dark mode, scaled to 960x600
//   <slug>.mp4   about five seconds of the app in use, 800x500, muted, H.264
//
// Dark mode: the browser asks for it (colorScheme "dark"), which every
// showcase app answers through prefers-color-scheme. An app with its own theme
// toggle (studio-engine apps keep the theme in a "dark" class on <html>) is
// switched to dark too, so a saved light preference cannot win.
//
// Motion: a known slug runs its own scenario below (Cyvasse sets up its army,
// Search Position runs a check); any other app gets a slow scroll down and
// back, which loops without a jump.
//
// --from <origin> loads the same path from another origin, e.g. a local copy of
// the app when production is asleep: --from http://127.0.0.1:3901
//
// Production cannot run a browser, so an agent runs this locally and commits
// the files: see the launch-build-queue SOP, "Deliver it". Needs ffmpeg and
// cwebp (brew install ffmpeg webp).
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");
const { chromium } = require("playwright");

const VIEWPORT = { width: 1280, height: 800 };
const MOTION_SECONDS_MAX = 7;

// Scroll by `px` (negative is up) in small wheel steps, so it reads as a person.
async function glide(page, px, ms = 1600) {
  const steps = Math.max(1, Math.round(ms / 40));
  for (let i = 0; i < steps; i++) {
    await page.mouse.wheel(0, px / steps);
    await page.waitForTimeout(40);
  }
}

async function scrollLoop(page) {
  await page.mouse.move(640, 400);
  await page.waitForTimeout(500);
  await glide(page, 520, 2000);
  await page.waitForTimeout(500);
  await glide(page, -520, 2000);
  await page.waitForTimeout(300);
}

// Each scenario: `setup` brings the page to the state the still shows; `motion`
// is what the loop records, starting from that state. `stillAfterMotion` takes
// the still at the end of the loop instead.
const SCENARIOS = {
  // The still is the board once both armies stand; the loop is how it got
  // there: three army setups, then Ready brings the opponent's side in.
  cyvasse: {
    stillAfterMotion: true,
    async motion(page) {
      const press = (text) => page.locator("button:visible", { hasText: text }).first().click();
      await page.waitForTimeout(300);
      await press(/(Smart|Random) Setup/);
      await page.waitForTimeout(1100);
      await press(/New Setup/);
      await page.waitForTimeout(1100);
      await press(/New Setup/);
      await page.waitForTimeout(1100);
      await press(/^Ready$/);
      await page.waitForTimeout(1800);
    }
  },
  // Type a check and run it; the still is the answer it gives.
  "search-position": {
    stillAfterMotion: true,
    async motion(page) {
      await page.waitForTimeout(300);
      await page.getByLabel("Search phrase").pressSequentially("best pizza in denver", { delay: 55 });
      await page.getByLabel("Your site").pressSequentially("reddit.com", { delay: 55 });
      await page.waitForTimeout(250);
      await Promise.all([page.waitForLoadState("load"), page.getByRole("button", { name: "Check position" }).click()]);
      await page.waitForTimeout(2200);
    }
  }
};

function usage() {
  console.error("usage: node script/gallery_capture.cjs <https-url> <slug> [--from <origin>]  (slug: a-z, 0-9, hyphens)");
  process.exit(2);
}

(async () => {
  const args = process.argv.slice(2);
  const fromAt = args.indexOf("--from");
  const from = fromAt >= 0 ? args.splice(fromAt, 2)[1] : null;
  const [url, slug] = args;
  if (!url || !/^https:\/\//.test(url) || !/^[a-z0-9][a-z0-9-]*$/.test(slug || "")) usage();
  const target = from ? new URL(new URL(url).pathname + new URL(url).search, from).href : url;

  const dir = path.join(__dirname, "..", "app/assets/images/build_gallery");
  const work = fs.mkdtempSync(path.join(os.tmpdir(), `gallery-${slug}-`));
  const scenario = SCENARIOS[slug] || {};
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({
      viewport: VIEWPORT, deviceScaleFactor: 1, colorScheme: "dark", reducedMotion: "no-preference",
      recordVideo: { dir: work, size: VIEWPORT }
    });
    const page = await context.newPage();
    const opened = Date.now();
    const response = await page.goto(target, { waitUntil: "load", timeout: 30000 });
    if (!response || !response.ok()) throw new Error(`${target} answered ${response && response.status()}`);
    // A studio-engine theme toggle keeps its own preference; ask it for dark.
    await page.evaluate(() => {
      const root = document.documentElement;
      if (window.Alpine && window.Alpine.store && window.Alpine.store("theme") && !root.classList.contains("dark")) {
        window.Alpine.store("theme").toggle();
      }
    });
    await page.waitForTimeout(1200); // fonts, images and entrance animations settle
    if (scenario.setup) await scenario.setup(page);

    const png = path.join(work, "still.png");
    if (!scenario.stillAfterMotion) await page.screenshot({ path: png });

    const start = (Date.now() - opened) / 1000;
    await (scenario.motion || scrollLoop)(page);
    const length = Math.min((Date.now() - opened) / 1000 - start, MOTION_SECONDS_MAX);
    if (scenario.stillAfterMotion) await page.screenshot({ path: png });
    const still = path.join(dir, `${slug}.webp`);
    execFileSync("cwebp", ["-quiet", "-q", "80", "-resize", "960", "600", png, "-o", still]);
    const video = await page.video().path();
    await context.close(); // finishes the recording

    const motion = path.join(dir, `${slug}.mp4`);
    execFileSync("ffmpeg", [
      "-loglevel", "error", "-y", "-ss", start.toFixed(2), "-t", length.toFixed(2), "-i", video,
      "-vf", "scale=800:500:flags=lanczos,fps=24", "-an", "-c:v", "libx264", "-preset", "slow", "-crf", "30",
      "-pix_fmt", "yuv420p", "-movflags", "+faststart", motion
    ]);
    for (const file of [still, motion]) {
      console.log(`wrote ${path.relative(process.cwd(), file)} (${Math.round(fs.statSync(file).size / 1024)} KB)`);
    }
  } finally {
    await browser.close();
    fs.rmSync(work, { recursive: true, force: true });
  }
})().catch((e) => { console.error(`gallery_capture: ${e.message}`); process.exit(1); });
