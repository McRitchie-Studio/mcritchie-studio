// The logo gallery's edit panel (/logos/:brand on the Navbar and Stacked tabs, task logo-part-editor;
// app/views/logos/_edit_panel.html.erb).
//
// 1. THE EDIT FORM submits itself on any change. Its blank fields ("As styled", a shown
//    tagline) are left out of the URL, so an unedited part names nothing. The page keeps
//    its scroll across the load, so picking colours in a row does not jump to the top.
//
//      <form data-logo-edit> … <input type="radio" name="first_colour" value="635BB2">
//
// 2. A PICKED COLOUR UNDER 3:1 against the page's background gets a one-line warning: the
//    operator may pick a colour that disappears on this theme, and should know it. It is
//    measured again whenever the hub theme turns (html.dark), since the page's background
//    changes with it and the logos follow by CSS alone.
//
//      <p hidden data-edit-contrast="#635BB2" data-name="Deep Violet">

export const MIN_CONTRAST = 3;

// "#635BB2" or "635bb2" as [r, g, b] (0-255); null for anything else.
export function hexToRgb(hex) {
  const match = /^#?([0-9a-f]{6})$/i.exec(String(hex).trim());
  if (!match) return null;
  const n = parseInt(match[1], 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

// WCAG 2 relative luminance of [r, g, b].
export function luminance([r, g, b]) {
  const lin = (c) => {
    const s = c / 255;
    return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

// WCAG 2 contrast ratio of two [r, g, b] colours, from 1 to 21.
export function contrastRatio(a, b) {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

// The warning for a colour of `ratio` against the page, or "" when it reads well enough.
export function contrastWarning(name, ratio) {
  if (ratio >= MIN_CONTRAST) return "";
  return `${name} measures ${ratio.toFixed(1)}:1 against this page's background, under ${MIN_CONTRAST}:1: it may be hard to see here.`;
}

// The form's fields that would put nothing in the URL: a blank value ("As styled", a shown tagline).
export function blankFields(fields) {
  return Array.from(fields).filter((field) => field.name && field.value === "" && !field.disabled);
}

// [r, g, b] of a computed CSS colour, any syntax the browser speaks (rgb(), oklch(), …), read back through a
// canvas pixel; null when it is transparent.
function cssColourToRgb(colour) {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  if (!ctx) return null;
  ctx.clearRect(0, 0, 1, 1);
  ctx.fillStyle = colour;
  ctx.fillRect(0, 0, 1, 1);
  const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
  return a === 0 ? null : [r, g, b];
}

// The colour the logos are drawn on: the first opaque background up from a logo's frame, else white.
export function pageBackground(start) {
  for (let el = start; el && el.nodeType === 1; el = el.parentElement) {
    const rgb = cssColourToRgb(getComputedStyle(el).backgroundColor);
    if (rgb) return rgb;
  }
  return [255, 255, 255];
}

function measure(root = document) {
  const frame = root.querySelector("[data-test='logo-frame']");
  const background = pageBackground(frame || document.body);
  root.querySelectorAll("[data-edit-contrast]").forEach((note) => {
    const rgb = hexToRgb(note.dataset.editContrast);
    const words = rgb ? contrastWarning(note.dataset.name || note.dataset.editContrast, contrastRatio(rgb, background)) : "";
    note.textContent = words;
    note.hidden = words === "";
  });
}

let keptScroll = null;

function wireForm(form) {
  if (form.dataset.logoEditWired) return;
  form.dataset.logoEditWired = "1";
  form.addEventListener("change", () => {
    blankFields(form.elements).forEach((field) => {
      field.disabled = true;
      field.dataset.blankDisabled = "1";
    });
    keptScroll = window.scrollY;
    form.requestSubmit();
  });
}

let themeWatch = null;

export function installLogoEditor(root = document) {
  root.querySelectorAll("form[data-logo-edit]").forEach(wireForm);
  if (keptScroll !== null) {
    // Now, and again once the logos have loaded: until then the page can be too short to reach the old position.
    const y = keptScroll;
    keptScroll = null;
    window.scrollTo(0, y);
    const images = Array.from(root.querySelectorAll("img[data-test='logo-image']"));
    Promise.all(images.map((img) => (img.complete ? null : img.decode().catch(() => null)))).then(() => window.scrollTo(0, y));
  }
  if (!root.querySelector("[data-edit-contrast]")) return;
  measure(root);
  if (!themeWatch) {
    // Again a moment later: a background that eases between themes reads half-way at first.
    themeWatch = new MutationObserver(() => {
      measure();
      setTimeout(() => measure(), 400);
    });
    themeWatch.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
  }
}

// Turbo keeps a copy of the page to show on Back, with the wired marker and the blank fields disabled on the way out
// but no listeners: clear both so the restored page is wired afresh and sends its fields.
export function clearForCache(root = document) {
  root.querySelectorAll("form[data-logo-edit]").forEach((form) => {
    delete form.dataset.logoEditWired;
    form.querySelectorAll("[data-blank-disabled]").forEach((field) => {
      field.disabled = false;
      delete field.dataset.blankDisabled;
    });
  });
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:before-cache", () => clearForCache());
  document.addEventListener("turbo:load", () => installLogoEditor());
  if (document.readyState !== "loading") installLogoEditor();
}
