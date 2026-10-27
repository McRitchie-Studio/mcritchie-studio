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
//
//    A spectrum step is the same button. The spectrum's Copy CSS tokens button copies a whole block the same
//    way; its data-copy-name ("CSS tokens") is what the status says it copied, in place of the block itself.
//
// 4. A COPY SVG BUTTON fetches its logo from the logo's own URL (the Download link's, without
//    download=1) on click and puts the SVG on the clipboard, then says Copied or Copy failed
//    for a moment (task logo-gallery-polish-pass: the page used to carry every SVG inline,
//    about 1.5 MB on /logos/turf). Safari only lets the clipboard be written inside the click
//    itself, so the write starts there with a promise of the text (ClipboardItem); a browser
//    without that falls back to fetching first and then writing the text.
//
//      <button data-copy-svg="/logos/turf/navbar?rule=4&…"> … <span data-copy-svg-label> … <span data-copy-svg-status>

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

export function wireSwatch(button) {
  if (button.dataset.copyHexWired) return;
  button.dataset.copyHexWired = "1";
  const label = button.querySelector("[data-copy-hex-label]");
  const status = button.parentElement.querySelector("[data-copy-hex-status]");
  // Kept on the label, not read afresh: a Turbo snapshot taken mid-"Copied" is re-wired on Back with that word showing.
  const rest = label ? (label.dataset.copyHexRest ??= label.textContent) : "";
  let timer;
  button.addEventListener("click", () => {
    const hex = button.dataset.copyHex;
    Promise.resolve(window.copyText(hex))
      .then((ok) => (ok === false ? "Copy failed" : "Copied"), () => "Copy failed")
      .then((word) => {
        if (label) label.textContent = word;
        if (status) status.textContent = word === "Copied" ? `Copied ${button.dataset.copyName || hex}` : word;
        clearTimeout(timer);
        timer = setTimeout(() => {
          if (label) label.textContent = rest;
          if (status) status.textContent = "";
        }, 1600);
      });
  });
}

// The SVG at `url`, as text: refused unless the answer is a 2xx SVG (a fetch resolves on a 404, and a signed-out
// request is answered with a page, not a logo).
export function fetchSvg(url, fetchFn) {
  return fetchFn(url, { credentials: "same-origin" }).then((response) => {
    const type = (response.headers && response.headers.get("content-type")) || "";
    if (!response.ok || !type.includes("image/svg+xml")) throw new Error(`no SVG at ${url} (${response.status} ${type})`);
    return response.text();
  });
}

// Puts the SVG at `url` on the clipboard and resolves true, or rejects. Call it inside the click: the first write
// starts at once, with a promise of the text, which is what Safari needs; where that is missing or refused, the
// text is fetched and written afterwards (writeText, else the page's copyText).
export function copySvg(url, { clipboard, fetchFn, ClipboardItemCtor, copyText }) {
  const later = () => fetchSvg(url, fetchFn).then((text) => {
    if (clipboard && typeof clipboard.writeText === "function") return clipboard.writeText(text).then(() => true);
    return Promise.resolve(copyText ? copyText(text) : false).then((ok) => {
      if (ok === false) throw new Error("the clipboard refused the SVG");
      return true;
    });
  });
  if (clipboard && typeof clipboard.write === "function" && typeof ClipboardItemCtor === "function") {
    let item;
    try {
      const blob = fetchSvg(url, fetchFn).then((text) => new Blob([text], { type: "text/plain" }));
      blob.catch(() => {}); // the write below reports it
      item = new ClipboardItemCtor({ "text/plain": blob });
    } catch (_) {
      return later();
    }
    return clipboard.write([item]).then(() => true, later);
  }
  return later();
}

function wireCopySvg(button) {
  if (button.dataset.copySvgWired) return;
  button.dataset.copySvgWired = "1";
  const label = button.querySelector("[data-copy-svg-label]");
  const status = button.parentElement.querySelector("[data-copy-svg-status]");
  let timer;
  button.addEventListener("click", () => {
    copySvg(button.dataset.copySvg, {
      clipboard: navigator.clipboard,
      fetchFn: window.fetch.bind(window),
      ClipboardItemCtor: window.ClipboardItem,
      copyText: window.copyText,
    })
      .then(() => "Copied", () => "Copy failed")
      .then((word) => {
        if (label) label.textContent = word;
        if (status) status.textContent = word;
        clearTimeout(timer);
        timer = setTimeout(() => {
          if (label) label.textContent = "Copy SVG";
          if (status) status.textContent = "";
        }, 1600);
      });
  });
}

export function installLogoGallery(root = document) {
  root.querySelectorAll("[data-logo-theme]").forEach((el) => setTheme(el.dataset.logoTheme === "dark", env()));
  root.querySelectorAll("select[data-logo-context]").forEach(wireContext);
  root.querySelectorAll("button[data-copy-hex]").forEach(wireSwatch);
  root.querySelectorAll("button[data-copy-svg]").forEach(wireCopySvg);
}

// Turbo keeps a copy of the page to show on Back. The copy carries the wired markers (and a select disabled on the
// way out of a watermark page) but none of the listeners, so clear them first: the restored page is wired afresh.
export function clearForCache(root = document) {
  root.querySelectorAll("[data-logo-context-wired], [data-copy-hex-wired], [data-copy-svg-wired]").forEach((el) => {
    delete el.dataset.logoContextWired;
    delete el.dataset.copyHexWired;
    delete el.dataset.copySvgWired;
    if (el.matches("select")) el.disabled = false;
  });
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:before-cache", () => clearForCache());
  document.addEventListener("turbo:load", () => installLogoGallery());
  if (document.readyState !== "loading") installLogoGallery();
}
