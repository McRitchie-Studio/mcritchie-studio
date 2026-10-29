// The brand page's Download card (logos/_download_card, task logo-download-card), and the /logos table's one-click
// PNG and JPEG downloads (logos/_index_downloads, task logos-index-download-formats; at the end of this file).
//
// Some integrations take no SVG and want an exact pixel size, so the card can give the tab's logo as a PNG. The PNG is
// drawn HERE, in the browser: the logo's SVG is fetched from its own URL (the tone's data-svg), sized to the target,
// loaded as an image, drawn onto a canvas of exactly the chosen pixels and saved with toBlob. The logo's words are
// outlined paths, so the drawing needs no font; a guide drawing's labels are Helvetica or Arial, which every system
// has. The SVG is same-origin, so the canvas is never tainted.
//
//   <section data-logo-download data-watermark-page="false">
//     <input type="radio" name="tone" data-svg data-download-url data-filename data-natural-width data-natural-height
//            data-presets='[{"key":"w800","label":"800 × 94","width":800,"height":94,"fit":"fill"}, …]'>
//     <input type="radio" name="size" value="<preset key>|custom"> (in <label data-download-size-label>)
//     <input name="custom_width"> <input name="custom_height">
//     <input type="checkbox" name="keep_aspect">     <a data-download-link>  <p data-download-summary>  <p data-download-error>
//   and, on the page's logo frame, <div data-download-outline hidden>: the canvas, dotted, when it is not the logo's shape.
//
// A preset's sizes come from the server (Logos::PngSizes); a custom size with its aspect kept is rounded here by the
// same rule: the side last typed as given, the other rounded to the nearest pixel, halves up, never below 1. With the
// aspect not kept (task brand-page-split-layout) both sides are as typed and the logo is fitted inside, centred.

export const MAX_SIDE = 8192;

// The PNG size for a custom side, or null when the value is not a whole number from 1 to MAX_SIDE or the other side
// would pass MAX_SIDE.
export function pngSize(axis, value, naturalWidth, naturalHeight) {
  const side = Number(value);
  if (!Number.isInteger(side) || side < 1 || side > MAX_SIDE) return null;
  const round = (n) => Math.max(1, Math.floor(n + 0.5));
  const size = axis === "height"
    ? { width: round((side * naturalWidth) / naturalHeight), height: side }
    : { width: side, height: round((side * naturalHeight) / naturalWidth) };
  return size.width > MAX_SIDE || size.height > MAX_SIDE ? null : size;
}

// A custom canvas from the card's Width and Height. With `keep` the side last typed (`axis`) sets the other from the
// drawing's shape; without it both are as given and the drawing is fitted inside ("contain"), so N × N pads an icon
// to a square. Null when a side is not a whole number from 1 to MAX_SIDE.
export function customSize({ width, height, keep, axis = "width" }, naturalWidth, naturalHeight) {
  if (keep) {
    const size = pngSize(axis, axis === "height" ? height : width, naturalWidth, naturalHeight);
    return size && { ...size, fit: "fill" };
  }
  const w = pngSize("width", width, 1, 1);
  const h = pngSize("width", height, 1, 1);
  return w && h ? { width: w.width, height: h.width, fit: "contain" } : null;
}

// Where the canvas outline sits around the logo as the page shows it: the drawing's box on the page (`shown`, in px)
// scaled out to the whole canvas, by where drawRect puts the drawing on it. Returns { left, top, width, height } in
// the same px, relative to the same origin as `shown`.
export function outlineRect(shown, size, naturalWidth, naturalHeight) {
  const rect = drawRect(size.fit, size.width, size.height, naturalWidth, naturalHeight);
  const k = shown.width / rect.width;
  return { left: shown.left - rect.x * k, top: shown.top - rect.y * k, width: size.width * k, height: size.height * k };
}

// Where the drawing goes on a canvas of width × height: the whole canvas ("fill"), or fitted inside it and centred
// ("contain": a square icon preset around an icon that is not square).
export function drawRect(fit, width, height, naturalWidth, naturalHeight) {
  if (fit !== "contain") return { x: 0, y: 0, width, height };
  const scale = Math.min(width / naturalWidth, height / naturalHeight);
  const w = naturalWidth * scale;
  const h = naturalHeight * scale;
  return { x: (width - w) / 2, y: (height - h) / 2, width: w, height: h };
}

// The PNG's name: the SVG's, with its size: studio-icon-light.svg at 512 × 512 is studio-icon-light-512x512.png.
export function pngFilename(svgFilename, width, height) {
  return `${svgFilename.replace(/\.svg$/i, "")}-${width}x${height}.png`;
}

// The SVG with its root's width and height set to the size it is drawn at, so the browser rasterises the vector at
// that size (Safari otherwise draws it at its own size and scales the pixels).
export function sizedSvg(text, width, height) {
  return text.replace(/<svg\b[^>]*>/, (tag) => {
    const set = (t, name, value) => (new RegExp(`\\s${name}="[^"]*"`).test(t)
      ? t.replace(new RegExp(`(\\s${name}=")[^"]*(")`), `$1${value}$2`)
      : t.replace(/<svg\b/, `<svg ${name}="${value}"`));
    return set(set(tag, "width", width), "height", height);
  });
}

// What the card is set to: { format, toneName, presets, tone (its radio's dataset), naturalWidth, naturalHeight,
// size: { width, height, fit } | null }. A PNG from the card is transparent: drawSvg gets no background.
export function readCard(card) {
  const form = card.querySelector("[data-download-form]");
  const value = (name) => { const el = form.querySelector(`[name="${name}"]:checked`) || form.elements[name]; return el ? el.value : null; };
  const tone = form.querySelector('input[name="tone"]:checked');
  const data = tone.dataset;
  const naturalWidth = Number(data.naturalWidth);
  const naturalHeight = Number(data.naturalHeight);
  const key = form.elements.size.value;
  const presets = JSON.parse(data.presets);
  let size = null;
  if (key === "custom") {
    size = customSize({
      width: form.elements.custom_width.value,
      height: form.elements.custom_height.value,
      keep: form.elements.keep_aspect.checked,
      axis: form.dataset.customAxis || "width",
    }, naturalWidth, naturalHeight);
  } else {
    const preset = presets.find((p) => p.key === key);
    size = preset ? { width: preset.width, height: preset.height, fit: preset.fit } : null;
  }
  return {
    format: value("format") || "svg",
    toneName: tone.value,
    presets,
    tone: data,
    naturalWidth,
    naturalHeight,
    size,
  };
}

// Names the size buttons for a tone's presets (each tone's drawing, so its sizes, can differ slightly): a key the tone
// lacks hides its button, and a hidden choice falls back to the first preset.
function setSizes(form, presets) {
  form.querySelectorAll("[data-download-size-label]").forEach((label) => {
    const preset = presets.find((p) => p.key === label.dataset.downloadSizeLabel);
    label.hidden = !preset;
    if (preset) label.querySelector("[data-size-text]").textContent = String(Math.max(preset.width, preset.height)); // its long side
  });
  const chosen = form.querySelector('input[name="size"]:checked');
  if (chosen && chosen.closest("label").hidden && presets[0]) form.elements.size.value = presets[0].key;
}

// The logo's SVG, as text, from its own URL; refused unless the answer is an SVG.
export async function fetchSvg(url, deps) {
  const response = await deps.fetchFn(url, { credentials: "same-origin" });
  const type = (response.headers && response.headers.get("content-type")) || "";
  if (!response.ok || !type.includes("image/svg+xml")) throw new Error(`no SVG at ${url} (${response.status})`);
  return response.text();
}

// Draws the PNG and resolves with its Blob. `deps` carries the browser (fetchFn, createImage, createCanvas, URL) so
// the order of the steps is testable.
export async function rasterise(url, options, deps) {
  return drawSvg(await fetchSvg(url, deps), options, deps);
}

// Draws SVG text onto a canvas of `size` and resolves with its Blob: a PNG unless `mime` says otherwise ("image/jpeg").
// `background` (a CSS colour) fills the canvas first; without one the canvas stays transparent.
export async function drawSvg(text, { size, naturalWidth, naturalHeight, background, mime = "image/png" }, deps) {
  const rect = drawRect(size.fit, size.width, size.height, naturalWidth, naturalHeight);
  const svg = sizedSvg(text, rect.width, rect.height);
  const objectUrl = deps.URL.createObjectURL(new Blob([svg], { type: "image/svg+xml" }));
  try {
    const image = deps.createImage();
    image.src = objectUrl;
    await image.decode();
    const canvas = deps.createCanvas(size.width, size.height);
    const context = canvas.getContext("2d");
    if (background) {
      context.fillStyle = background;
      context.fillRect(0, 0, size.width, size.height);
    }
    context.drawImage(image, rect.x, rect.y, rect.width, rect.height);
    return await new Promise((resolve, reject) => canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error(`the canvas gave no ${mime}`))), mime));
  } finally {
    deps.URL.revokeObjectURL(objectUrl);
  }
}

function browserDeps() {
  return {
    fetchFn: window.fetch.bind(window),
    createImage: () => new Image(),
    createCanvas: (width, height) => Object.assign(document.createElement("canvas"), { width, height }),
    URL: window.URL,
  };
}

function save(blob, filename) {
  const url = URL.createObjectURL(blob);
  const link = Object.assign(document.createElement("a"), { href: url, download: filename });
  link.hidden = true;
  document.body.appendChild(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
}

// Writes a live status line only when its text changes (and, with hideWhenEmpty, shows or hides it only then): the
// ResizeObserver re-syncs the card on every image resize, and a screen reader would otherwise hear the same line again.
export function announce(el, text, { hideWhenEmpty = false } = {}) {
  if (el.textContent !== text) el.textContent = text;
  if (hideWhenEmpty && el.hidden !== (text === "")) el.hidden = text === "";
}

function wireCard(card) {
  if (card.dataset.logoDownloadWired) return;
  card.dataset.logoDownloadWired = "1";
  const form = card.querySelector("[data-download-form]");
  const link = card.querySelector("[data-download-link]");
  const summary = card.querySelector("[data-download-summary]");
  const error = card.querySelector("[data-download-error]");
  const pngOnly = card.querySelector("[data-png-only]");
  const outline = document.querySelector("[data-download-outline]");
  card.querySelectorAll("[data-download-js]").forEach((el) => { el.hidden = false; });

  // The tone the theme shows, unless this is a watermark page.
  if (card.dataset.watermarkPage !== "true" && document.documentElement.classList.contains("dark")) {
    const dark = form.querySelector('input[name="tone"][value="dark"]');
    if (dark) dark.checked = true;
  }
  let toneName = null;
  let tone = null;
  const say = (text) => announce(summary, text);
  const warn = (text) => announce(error, text, { hideWhenEmpty: true });

  const sync = () => {
    const state = readCard(card);
    if (state.toneName !== toneName) {
      toneName = state.toneName;
      tone = state.tone;
      setSizes(form, state.presets);
      fillSize(true);
      return sync();
    }
    const png = state.format === "png";
    pngOnly.hidden = !png;
    form.elements.keep_aspect.disabled = form.elements.size.value !== "custom"; // a standard size keeps the logo's shape
    link.href = tone.downloadUrl;
    link.setAttribute("aria-label", `Download ${png ? "PNG" : "SVG"}: ${tone.label}`);
    placeOutline(png ? state : null);
    if (!png) {
      warn("");
      say(tone.filename);
    } else if (state.size) {
      const shape = state.size.fit === "fill" ? "true aspect" : "fitted, centred";
      warn("");
      say(`${pngFilename(tone.filename, state.size.width, state.size.height)} · ${state.size.width} × ${state.size.height} px, ${shape}, transparent`);
    } else {
      // The error line is the one announcement; the summary empties rather than repeat it.
      say("");
      warn(`A custom side is a whole number of pixels, 1 to ${MAX_SIDE}, and the other side may not pass ${MAX_SIDE}.`);
    }
    return state;
  };

  // The dotted canvas on the page's logo, when the PNG's canvas is not the logo's own shape.
  const placeOutline = (state) => {
    if (!outline) return;
    const frame = outline.parentElement;
    const image = [...frame.querySelectorAll("img")].find((img) => img.getBoundingClientRect().width > 0);
    if (!state || !state.size || state.size.fit !== "contain" || !image) { outline.hidden = true; return; }
    const box = image.getBoundingClientRect();
    const origin = frame.getBoundingClientRect();
    const shown = { left: box.left - origin.left - frame.clientLeft, top: box.top - origin.top - frame.clientTop, width: box.width, height: box.height };
    const rect = outlineRect(shown, state.size, state.naturalWidth, state.naturalHeight);
    Object.assign(outline.style, { left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px` });
    outline.hidden = false;
  };

  // A standard size writes its Width × Height into the inputs, and keeps the aspect, so they always show the PNG's size.
  const fillSize = (picked) => {
    if (form.elements.size.value === "custom") return;
    const state = readCard(card);
    if (!state.size) return;
    form.elements.custom_width.value = state.size.width;
    form.elements.custom_height.value = state.size.height;
    if (picked) form.elements.keep_aspect.checked = true;
  };

  // Typing a side picks Custom. Keep aspect ratio: the side typed sets the other, in the inputs themselves.
  const followAspect = (event) => {
    const width = form.elements.custom_width;
    const height = form.elements.custom_height;
    if (event && (event.target === width || event.target === height)) {
      form.dataset.customAxis = event.target === height ? "height" : "width";
      form.elements.size.value = "custom";
    }
    if (event && event.target.name === "size") return fillSize(true);
    if (!form.elements.keep_aspect.checked || form.elements.size.value !== "custom") return;
    const state = readCard(card);
    if (!state.size) return;
    if (form.dataset.customAxis === "height") width.value = state.size.width;
    else height.value = state.size.height;
  };

  form.addEventListener("change", (event) => { followAspect(event); sync(); });
  form.addEventListener("input", (event) => { followAspect(event); sync(); });
  // The outline follows the logo: its image loading and the theme swapping light for dark
  // (the observer watches the images, so a window resize that leaves them their size redraws nothing).
  if (outline && typeof ResizeObserver !== "undefined") {
    const observer = new ResizeObserver(() => (card.isConnected ? sync() : observer.disconnect()));
    outline.parentElement.querySelectorAll("img").forEach((img) => observer.observe(img));
  }
  form.addEventListener("submit", (event) => event.preventDefault());
  link.addEventListener("click", (event) => {
    const state = sync();
    if (state.format !== "png") return; // the link downloads the SVG itself
    event.preventDefault();
    if (!state.size) return;
    link.setAttribute("aria-busy", "true");
    rasterise(state.tone.svg, state, browserDeps())
      .then((blob) => save(blob, pngFilename(state.tone.filename, state.size.width, state.size.height)))
      .catch((failure) => warn(`The PNG could not be drawn: ${failure.message}`))
      .finally(() => link.removeAttribute("aria-busy"));
  });
  sync();
}

// ---- The /logos table's one-click downloads (logos/_index_downloads, task logos-index-download-formats) ----
//
//   <table data-download-format="png|svg|jpeg"> … <a data-logo-raster href="<the SVG download>" data-svg data-filename
//      data-background data-raster-size="width:800|long:512" data-label>
//
// Every link's href is the SVG download, so with JavaScript off, or in the SVG format, the link does its own work. In
// PNG or JPEG this takes the click, fetches the logo's SVG, reads its drawing's size from its viewBox, and draws it at
// the type's default preset (Logos::PngSizes.default_size) as the Download card does.

export const RASTER_FORMATS = { png: { mime: "image/png", ext: "png", label: "PNG" }, jpeg: { mime: "image/jpeg", ext: "jpg", label: "JPEG" } };

// The drawing's own width and height, from its root viewBox (Logos::PngSizes.natural), or null.
export function naturalSize(text) {
  const root = /<svg\b[^>]*>/.exec(text);
  const box = root && /\bviewBox="([^"]+)"/.exec(root[0]);
  if (!box) return null;
  const [, , width, height] = box[1].trim().split(/[\s,]+/).map(Number);
  return width > 0 && height > 0 ? { width, height } : null;
}

// The canvas for a default preset spec: "width:800" sets the width, the height following; "long:512" sets an icon's
// long side, the other following, and a drawing within 1% of square (Logos::PngSizes::SQUARE_TOLERANCE) is N × N with
// the drawing fitted inside, as the server's icon presets are. Null when the size cannot be drawn.
export function rasterSize(spec, naturalWidth, naturalHeight) {
  const [kind, raw] = String(spec).split(":");
  const value = Number(raw);
  if (kind === "long") {
    if (Math.abs(naturalWidth / naturalHeight - 1) <= 0.01) {
      const side = pngSize("width", value, 1, 1);
      return side && { ...side, fit: "contain" };
    }
    const size = pngSize(naturalWidth >= naturalHeight ? "width" : "height", value, naturalWidth, naturalHeight);
    return size && { ...size, fit: "fill" };
  }
  if (kind !== "width") return null;
  const size = pngSize("width", value, naturalWidth, naturalHeight);
  return size && { ...size, fit: "fill" };
}

// The file's name: the SVG's, with its size and the format's extension (studio-icon-light-512x416.jpg).
export function rasterFilename(svgFilename, width, height, ext) {
  return `${svgFilename.replace(/\.svg$/i, "")}-${width}x${height}.${ext}`;
}

// What one table link would draw in `format`: { url, filename, mime, size, naturalWidth, naturalHeight, background }
// once the SVG is read. A JPEG has no transparency, so it is always filled: with the link's data-background, the tone's
// solid background (Logos::PngSizes::BACKGROUNDS). A PNG stays transparent, as the brand page's card always is.
export function rasterPlan(data, format, text) {
  const raster = RASTER_FORMATS[format];
  if (!raster) return null;
  const natural = naturalSize(text);
  if (!natural) throw new Error("the SVG has no viewBox");
  const size = rasterSize(data.rasterSize, natural.width, natural.height);
  if (!size) throw new Error(`no ${raster.label} size for ${data.rasterSize}`);
  return {
    size,
    naturalWidth: natural.width,
    naturalHeight: natural.height,
    mime: raster.mime,
    background: format === "jpeg" ? data.background : null,
    filename: rasterFilename(data.filename, size.width, size.height, raster.ext),
  };
}

// The format a table link downloads in: its table's data-download-format, else SVG.
export function tableFormat(link) {
  const table = link.closest("[data-download-format]");
  return (table && table.dataset.downloadFormat) || "svg";
}

// Draws one table link's file and saves it. Resolves with the plan, or null when the link downloads its SVG itself.
export async function downloadTableLink(link, deps, saveFn = save) {
  const format = tableFormat(link);
  if (!RASTER_FORMATS[format]) return null;
  const text = await fetchSvg(link.dataset.svg, deps);
  const plan = rasterPlan(link.dataset, format, text);
  saveFn(await drawSvg(text, plan, deps), plan.filename);
  return plan;
}

function onTableClick(event) {
  const link = event.target.closest && event.target.closest("a[data-logo-raster]");
  if (!link || !RASTER_FORMATS[tableFormat(link)]) return; // the SVG: the link's own download
  if (event.defaultPrevented || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
  event.preventDefault();
  if (link.getAttribute("aria-busy") === "true") return;
  const error = document.querySelector("[data-logo-raster-error]");
  if (error) error.hidden = true;
  link.setAttribute("aria-busy", "true");
  downloadTableLink(link, browserDeps())
    .catch((failure) => {
      if (!error) return;
      error.textContent = `The ${RASTER_FORMATS[tableFormat(link)].label} could not be drawn (${link.dataset.label}): ${failure.message}. The link's SVG still downloads with the SVG format.`;
      error.hidden = false;
    })
    .finally(() => link.removeAttribute("aria-busy"));
}

// A default preset spec in words, for a link's accessible name: "800 px wide", "512 px on its long side".
export function sizeWords(spec) {
  const [kind, value] = String(spec).split(":");
  return kind === "long" ? `${value} px on its long side` : `${value} px wide`;
}

// A table link's accessible name in the table's format, built on the server's own label ("Download: <logo>, kit
// choice"), so the server's cues (the ", kit choice" a saved choice carries) survive: "Download PNG, 800 px wide: <logo>,
// kit choice". `serverLabel` is the label the page was served with; `fallback` names the logo when there is none.
export function tableLinkLabel(serverLabel, format, rasterSize, fallback = "") {
  const raster = RASTER_FORMATS[format];
  const named = String(serverLabel || "").replace(/^Download:\s*/, "") || fallback;
  return `Download ${raster ? `${raster.label}, ${sizeWords(rasterSize)}` : "SVG"}: ${named}`;
}

// Shows the format control (served hidden: without JavaScript every link is an SVG) and names each link's format.
// The served aria-label is kept once in data-server-label, so a second install (a Turbo visit) builds on it, not on
// its own last answer.
export function installTableDownloads(root = document) {
  root.querySelectorAll("[data-logo-raster-js]").forEach((el) => { el.hidden = false; });
  root.querySelectorAll("a[data-logo-raster]").forEach((link) => {
    if (link.dataset.serverLabel === undefined) link.dataset.serverLabel = link.getAttribute("aria-label") || "";
    link.setAttribute("aria-label", tableLinkLabel(link.dataset.serverLabel, tableFormat(link), link.dataset.rasterSize, link.dataset.label));
  });
}

export function installLogoDownload(root = document) {
  root.querySelectorAll("[data-logo-download]").forEach(wireCard);
  installTableDownloads(root);
}

// Turbo's Back copy carries the wired marker but not the listeners: clear it so the restored card is wired afresh.
export function clearLogoDownloadForCache(root = document) {
  root.querySelectorAll("[data-logo-download-wired]").forEach((el) => { delete el.dataset.logoDownloadWired; });
}

if (typeof document !== "undefined") {
  document.addEventListener("click", onTableClick);
  document.addEventListener("turbo:before-cache", () => clearLogoDownloadForCache());
  document.addEventListener("turbo:load", () => installLogoDownload());
  if (document.readyState !== "loading") installLogoDownload();
}
