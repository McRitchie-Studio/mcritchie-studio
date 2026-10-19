// The CTA glow primitive's behaviour (app/assets/tailwind/cta_glow.css;
// app/helpers/cta_glow_helper.rb sets the colours on the server).
//
//   - the theme card: picking an option ([data-glow-a] on its radio) moves the
//     glow behind Choose Theme ([data-build-theme-glow]) to that theme's
//     colours. The colours are registered CSS properties, so the browser blends
//     them. The glow is spent (data-glow="off") while the pick is the theme
//     already chosen (the card's data-chosen-index).
//   - every glow: one IntersectionObserver marks a CTA scrolled off screen
//     data-glow-visible="false", so it draws no blurred layer.
//
// Pure where it can be (themeGlowVars, syncThemeGlow take stand-ins), so
// test/javascript/cta_glow_test.js runs it without a browser.

export const GLOW_VARS = ["--glow-a", "--glow-b", "--glow-c"];

// The glow colours a theme option carries: { "--glow-a": "#…", … }, or null
// when it carries none.
export function themeGlowVars(option) {
  const d = option?.dataset || {};
  const colors = [d.glowA, d.glowB, d.glowC];
  if (colors.some((c) => !/^#[0-9a-f]{6}$/i.test(c || ""))) return null;
  return Object.fromEntries(GLOW_VARS.map((name, i) => [name, colors[i]]));
}

// The theme card's glow follows its checked option. Returns the vars applied.
export function syncThemeGlow(card) {
  const glow = card.querySelector("[data-build-theme-glow]");
  const option = card.querySelector("input[name='index']:checked");
  if (!glow || !option) return null;
  const vars = themeGlowVars(option);
  if (vars) Object.entries(vars).forEach(([name, value]) => glow.style.setProperty(name, value));
  const spent = card.dataset.chosenIndex !== undefined && card.dataset.chosenIndex !== "" && option.value === card.dataset.chosenIndex;
  if (spent) glow.dataset.glow = "off"; else delete glow.dataset.glow;
  return vars;
}

let observer = null;

// Watches every .cta-glow under root (new ones too: call again after a render).
export function watchGlows(root = document) {
  if (typeof IntersectionObserver === "undefined") return;
  observer ||= new IntersectionObserver((entries) => {
    entries.forEach((entry) => { entry.target.dataset.glowVisible = String(entry.isIntersecting); });
  });
  root.querySelectorAll(".cta-glow:not([data-glow-watched])").forEach((el) => {
    el.dataset.glowWatched = "true";
    observer.observe(el);
  });
}
