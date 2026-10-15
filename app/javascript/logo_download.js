// The brand page's Download card (logos/_download_card, task logo-download-card).
//
// Some integrations take no SVG and want an exact pixel size, so the card can give the tab's logo as a PNG. The PNG is
// drawn HERE, in the browser: the logo's SVG is fetched from its own URL (the one Copy SVG uses), sized to the target,
// loaded as an image, drawn onto a canvas of exactly the chosen pixels and saved with toBlob. The logo's words are
// outlined paths, so the drawing needs no font; a guide drawing's labels are Helvetica or Arial, which every system
// has. The SVG is same-origin, so the canvas is never tainted.
//
//   <section data-logo-download data-watermark-page="false">
//     <input type="radio" name="tone" data-svg data-download-url data-filename data-natural-width data-natural-height
//            data-presets='[{"key":"w800","label":"800 × 94","width":800,"height":94,"fit":"fill"}, …]' data-background>
//     <select name="size"> … <option value="custom">     <input name="custom_value"> <select name="custom_axis">
//     <a data-download-link>  <button data-copy-svg>  <p data-download-summary>  <p data-download-error>
//
// A preset's sizes come from the server (Logos::PngSizes); a custom size is rounded here by the same rule: the set side
// as given, the other side rounded to the nearest pixel, halves up, never below 1.

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

// What the card is set to: { format, tone (its radio's dataset), size: { width, height, fit } | null, background }.
export function readCard(card) {
  const form = card.querySelector("[data-download-form]");
  const value = (name) => { const el = form.querySelector(`[name="${name}"]:checked`) || form.elements[name]; return el ? el.value : null; };
  const tone = form.querySelector('input[name="tone"]:checked');
  const data = tone.dataset;
  const naturalWidth = Number(data.naturalWidth);
  const naturalHeight = Number(data.naturalHeight);
  const key = form.elements.size.value;
  let size = null;
  if (key === "custom") {
    const custom = pngSize(form.elements.custom_axis.value, form.elements.custom_value.value, naturalWidth, naturalHeight);
    size = custom && { ...custom, fit: "fill" };
  } else {
    const preset = JSON.parse(data.presets).find((p) => p.key === key);
    size = preset ? { width: preset.width, height: preset.height, fit: preset.fit } : null;
  }
  return {
    format: value("format") || "svg",
    toneName: tone.value,
    tone: data,
    naturalWidth,
    naturalHeight,
    size,
    background: value("background") === "solid" ? form.elements.background_colour.value : null,
  };
}

function setOptions(select, presets) {
  const was = select.value;
  const custom = select.querySelector('option[value="custom"]');
  [...select.options].forEach((option) => { if (option !== custom) option.remove(); });
  presets.forEach((preset) => {
    const option = document.createElement("option");
    option.value = preset.key;
    option.textContent = `${preset.label} · ${preset.use}`;
    select.insertBefore(option, custom);
  });
  select.value = [...select.options].some((o) => o.value === was) ? was : (presets[0] ? presets[0].key : "custom");
}

// Draws the PNG and resolves with its Blob. `deps` carries the browser (fetchFn, createImage, createCanvas, URL) so
// the order of the steps is testable.
export async function rasterise(url, { size, naturalWidth, naturalHeight, background }, deps) {
  const response = await deps.fetchFn(url, { credentials: "same-origin" });
  const type = (response.headers && response.headers.get("content-type")) || "";
  if (!response.ok || !type.includes("image/svg+xml")) throw new Error(`no SVG at ${url} (${response.status})`);
  const rect = drawRect(size.fit, size.width, size.height, naturalWidth, naturalHeight);
  const svg = sizedSvg(await response.text(), rect.width, rect.height);
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
    return await new Promise((resolve, reject) => canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("the canvas gave no PNG"))), "image/png"));
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

function wireCard(card) {
  if (card.dataset.logoDownloadWired) return;
  card.dataset.logoDownloadWired = "1";
  const form = card.querySelector("[data-download-form]");
  const link = card.querySelector("[data-download-link]");
  const copy = card.querySelector("[data-copy-svg]");
  const summary = card.querySelector("[data-download-summary]");
  const error = card.querySelector("[data-download-error]");
  const custom = card.querySelector("[data-download-custom]");
  const colour = card.querySelector("[data-download-colour]");
  const pngOnly = card.querySelector("[data-png-only]");
  card.querySelectorAll("[data-download-js]").forEach((el) => { el.hidden = false; });

  // The tone the theme shows, unless this is a watermark page.
  if (card.dataset.watermarkPage !== "true" && document.documentElement.classList.contains("dark")) {
    const dark = form.querySelector('input[name="tone"][value="dark"]');
    if (dark) dark.checked = true;
  }
  let toneName = null;
  let tone = null;

  const sync = () => {
    const state = readCard(card);
    if (state.toneName !== toneName) {
      toneName = state.toneName;
      tone = state.tone;
      setOptions(form.elements.size, JSON.parse(tone.presets));
      colour.value = tone.background;
      return sync();
    }
    const png = state.format === "png";
    pngOnly.hidden = !png;
    custom.hidden = form.elements.size.value !== "custom";
    colour.hidden = state.background === null;
    copy.dataset.copySvg = tone.svg;
    copy.setAttribute("aria-label", `Copy SVG: ${tone.label}`);
    link.textContent = png ? "Download PNG" : "Download SVG";
    link.href = tone.downloadUrl;
    link.setAttribute("aria-label", `Download ${png ? "PNG" : "SVG"}: ${tone.label}`);
    error.hidden = true;
    if (!png) {
      summary.textContent = tone.filename;
    } else if (state.size) {
      summary.textContent = `${pngFilename(tone.filename, state.size.width, state.size.height)} · ${state.size.width} × ${state.size.height} px, ${state.background ? `on ${state.background}` : "transparent"}`;
    } else {
      summary.textContent = `A custom side is a whole number of pixels, 1 to ${MAX_SIDE}, and the other side may not pass ${MAX_SIDE}.`;
    }
    return state;
  };

  form.addEventListener("change", sync);
  form.addEventListener("input", sync);
  form.addEventListener("submit", (event) => event.preventDefault());
  link.addEventListener("click", (event) => {
    const state = sync();
    if (state.format !== "png") return; // the link downloads the SVG itself
    event.preventDefault();
    if (!state.size) return;
    link.setAttribute("aria-busy", "true");
    rasterise(state.tone.svg, state, browserDeps())
      .then((blob) => save(blob, pngFilename(state.tone.filename, state.size.width, state.size.height)))
      .catch((failure) => {
        error.textContent = `The PNG could not be drawn: ${failure.message}`;
        error.hidden = false;
      })
      .finally(() => link.removeAttribute("aria-busy"));
  });
  sync();
}

export function installLogoDownload(root = document) {
  root.querySelectorAll("[data-logo-download]").forEach(wireCard);
}

// Turbo's Back copy carries the wired marker but not the listeners: clear it so the restored card is wired afresh.
export function clearLogoDownloadForCache(root = document) {
  root.querySelectorAll("[data-logo-download-wired]").forEach((el) => { delete el.dataset.logoDownloadWired; });
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:before-cache", () => clearLogoDownloadForCache());
  document.addEventListener("turbo:load", () => installLogoDownload());
  if (document.readyState !== "loading") installLogoDownload();
}
