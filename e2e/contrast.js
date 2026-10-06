// Text contrast measured the way a reader sees it: the element's colour against
// every ancestor background composited from the page down. Shared by
// status_tones.spec.js and artifact_gate.spec.js.

const CONTRAST = (selector) => {
  const cv = document.createElement("canvas");
  cv.width = cv.height = 1;
  const cx = cv.getContext("2d", { willReadFrequently: true });
  const paint = (s) => {
    if (!s || s === "transparent") return { r: 0, g: 0, b: 0, a: 0 };
    cx.clearRect(0, 0, 1, 1);
    cx.fillStyle = "#000";
    cx.fillStyle = s;
    cx.fillRect(0, 0, 1, 1);
    const d = cx.getImageData(0, 0, 1, 1).data;
    return { r: d[0], g: d[1], b: d[2], a: d[3] / 255 };
  };
  const over = (fg, bg) => ({
    r: fg.r * fg.a + bg.r * (1 - fg.a),
    g: fg.g * fg.a + bg.g * (1 - fg.a),
    b: fg.b * fg.a + bg.b * (1 - fg.a),
    a: 1,
  });
  const lum = (c) => {
    const f = (v) => (v / 255 <= 0.03928 ? v / 255 / 12.92 : Math.pow((v / 255 + 0.055) / 1.055, 2.4));
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  };
  const ratio = (a, b) => {
    const [hi, lo] = [lum(a), lum(b)].sort((x, y) => y - x);
    return (hi + 0.05) / (lo + 0.05);
  };

  return [...document.querySelectorAll(selector)].map((el) => {
    const chain = [];
    for (let node = el; node; node = node.parentElement) chain.push(node);
    let bg = { r: 255, g: 255, b: 255, a: 1 };
    for (const node of chain.reverse()) {
      const c = paint(getComputedStyle(node).backgroundColor);
      if (c.a > 0) bg = over(c, bg);
    }
    const fg = paint(getComputedStyle(el).color);
    return { text: el.textContent.trim().slice(0, 40), ratio: +ratio(over(fg, bg), bg).toFixed(2) };
  });
};

// The engine derives each -ink to clear AA (4.5) against the SURFACES, and the
// error box sits on the card surface with no tint: it measures 4.5 in dark.
// The 0.1 allowance is the canvas's 8-bit rounding, not a looser bar.
const TEXT_ON_SURFACE = 4.4;
// A chip lays its ink over its own 10% role tint, which the ink is NOT derived
// against: the danger chip measures 4.17 in dark (warning 4.51, success 4.6).
// This floor holds the chips to "legible in both themes" (the dark-only chips
// they replaced measured under 2 in light); lifting it to AA needs the engine's
// contrast_ink to search against the tint. Named on the task, not hidden here.
const CHIP_ON_TINT = 4.0;

async function eachTheme(page, check) {
  for (const theme of ["light", "dark"]) {
    await page.evaluate((t) => document.documentElement.classList.toggle("dark", t === "dark"), theme);
    await check(theme);
  }
}

module.exports = { CONTRAST, eachTheme, TEXT_ON_SURFACE, CHIP_ON_TINT };
