// The logo gallery's behaviour (/logos and /logos/:brand, task brand-gallery-palette-and-theme).
//
// 1. THE CONTEXT CONTROL drives the hub's own theme, the switch the moon icon uses
//    ($store.theme.toggle() from studio-engine studio/alpine_stores: the root's `dark`
//    class and localStorage 'theme'). Light and Dark set the theme and the page's logos
//    follow it by CSS alone (html.dark), with no request. Watermark sets the theme to
//    dark and submits the form, which loads ?context=watermark. On a watermark page,
//    choosing Light or Dark, or the theme turning light, loads the page without it.
//    The control always shows the theme the page is in.
//
//      <select data-logo-context data-watermark="false"> inside the context GET form
//
// 2. A PAGE OPENED WITH AN EXPLICIT CONTEXT sets the hub theme to it:
//
//      <div data-logo-theme="dark">   (light, or dark for dark and watermark)
//
// 3. A PALETTE SWATCH copies its hex on click (window.copyText, from the page's
//    components/_copy_text_script), and says Copied or Copy failed for a moment.
//
//      <button data-copy-hex="#1A1535"> … <span data-copy-hex-label> … <span data-copy-hex-status>

// What the control should show: the watermark on a watermark page, else the theme.
export function contextShown(watermarkPage, dark) {
  if (watermarkPage) return "watermark";
  return dark ? "dark" : "light";
}

// What choosing `value` does: whether to flip the theme, and whether to load the page
// (with the watermark, or without it when leaving one).
export function choice(value, { watermarkPage, dark }) {
  const wantDark = value !== "light";
  return {
    toggle: wantDark !== dark,
    load: value === "watermark" ? "watermark" : watermarkPage ? "plain" : null,
  };
}

// Sets the theme the way the moon icon does: through the Alpine store when it is there,
// else the root's class and localStorage directly.
export function setTheme(dark, { root, storage, store }) {
  const isDark = () => root.classList.contains("dark");
  if (isDark() === dark) return;
  if (store && typeof store.toggle === "function") {
    store.toggle();
  } else {
    root.classList.toggle("dark", dark);
    try { storage.setItem("theme", dark ? "dark" : "light"); } catch (_) { /* private mode */ }
  }
}

function env() {
  const store = window.Alpine && window.Alpine.store && window.Alpine.store("theme");
  return { root: document.documentElement, storage: window.localStorage, store };
}

const isDark = () => document.documentElement.classList.contains("dark");

// Loads the page from the context form: with the watermark, or without it ("plain": the select is left out, and the
// hidden fields keep every other setting).
function load(select, how) {
  if (how === "plain") select.disabled = true;
  select.form.requestSubmit();
}

function wireContext(select) {
  if (select.dataset.logoContextWired) return;
  select.dataset.logoContextWired = "1";
  const watermarkPage = select.dataset.watermark === "true";
  let leaving = false;
  const leave = (how) => {
    if (leaving) return;
    leaving = true;
    load(select, how);
  };
  const sync = () => {
    if (watermarkPage && !isDark()) return leave("plain"); // the theme turned a watermark page light
    if (!leaving) select.value = contextShown(watermarkPage, isDark());
  };
  sync();
  new MutationObserver(sync).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
  select.addEventListener("change", () => {
    const { toggle, load: how } = choice(select.value, { watermarkPage, dark: isDark() });
    if (how) leave(how);
    if (toggle) setTheme(!isDark(), env());
  });
}

function wireSwatch(button) {
  if (button.dataset.copyHexWired) return;
  button.dataset.copyHexWired = "1";
  const label = button.querySelector("[data-copy-hex-label]");
  const status = button.parentElement.querySelector("[data-copy-hex-status]");
  let timer;
  button.addEventListener("click", () => {
    const hex = button.dataset.copyHex;
    Promise.resolve(window.copyText(hex))
      .then((ok) => (ok === false ? "Copy failed" : "Copied"), () => "Copy failed")
      .then((word) => {
        if (label) label.textContent = word;
        if (status) status.textContent = word === "Copied" ? `Copied ${hex}` : word;
        clearTimeout(timer);
        timer = setTimeout(() => {
          if (label) label.textContent = hex;
          if (status) status.textContent = "";
        }, 1600);
      });
  });
}

export function installLogoGallery(root = document) {
  root.querySelectorAll("[data-logo-theme]").forEach((el) => setTheme(el.dataset.logoTheme === "dark", env()));
  root.querySelectorAll("select[data-logo-context]").forEach(wireContext);
  root.querySelectorAll("button[data-copy-hex]").forEach(wireSwatch);
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:load", () => installLogoGallery());
  if (document.readyState !== "loading") installLogoGallery();
}
