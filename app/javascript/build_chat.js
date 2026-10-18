// The /build chat with Xan (app/views/build/_chat.html.erb; BuildController#turns).
// A signed-out visitor has no /cable socket, so instead of a Turbo stream the
// page POLLS: while any turn is still waiting for Xan (data-pending="true"), it
// asks the server about exactly those turns and renders the Turbo Streams it
// gets back (each turn replaced in place, and the checklist).
//
//   - every POLL_MS while something is pending, slowing to SLOW_MS once a turn
//     has waited SLOW_AFTER_MS (a dispatcher that is down should not be hammered);
//   - nothing at all on any other page, or when nothing is pending.
//
// Also the delegated behaviours a card may need however it arrived (on load or
// in a poll), so the templates carry no inline script:
//
//   - the domain card: each suggestion chip ([data-build-domain-chip]) is
//     checked once on arrival and disabled when /build/check says it is taken
//     (a tap on an available one submits the choice); the own-name field
//     ([data-build-address]) is cleaned as it is typed (the server's
//     AppRequest.normalize_subdomain, done again here) and checked live; a name
//     we KNOW is refused disables its button (the server re-checks on the tap);
//   - the CTO card ([data-build-cto]): the portrait or "New image" opens the
//     picker dialog; a pick swaps the preview; a tap on a portrait, Done or
//     Enter closes it (the arrow keys only move the pick); a tap on one of
//     Ray's names fills the name field;
//   - the theme card ([data-build-theme]): the Dark / Light toggle swaps every
//     column's preview, and the choice survives the card's re-render;
//   - Build My App signed out ([data-build-sign-in]): opens the standard
//     sign-in modal with the props the button carries.
//
// Imported by application.js on every page, once per load; one timer, which
// reads the page fresh on every tick, and listeners delegated on document, so
// a Turbo visit needs no re-binding.
import { Turbo } from "@hotwired/turbo-rails";

const POLL_MS = 2500;
const SLOW_MS = 10000;
const SLOW_AFTER_MS = 120000;
let waitingSince = null;
let inFlight = false;
let lastPoll = 0;

function pendingIds(root) {
  return Array.from(root.querySelectorAll('[data-build-turn][data-pending="true"]'))
    .map((turn) => turn.id.replace("build-turn-", ""))
    .filter((id) => /^\d+$/.test(id));
}

async function tick() {
  const root = document.querySelector("[data-build-chat]");
  if (!root || inFlight) return;
  const ids = pendingIds(root);
  if (ids.length === 0) { waitingSince = null; return; }
  const now = Date.now();
  waitingSince = waitingSince || now;
  const every = now - waitingSince > SLOW_AFTER_MS ? SLOW_MS : POLL_MS;
  if (now - lastPoll < every) return;
  lastPoll = now;
  inFlight = true;
  try {
    const url = `${root.dataset.buildChatPollUrl}?ids=${ids.slice(-10).join(",")}`;
    const response = await fetch(url, { headers: { Accept: "text/vnd.turbo-stream.html" }, credentials: "same-origin" });
    if (response.ok) Turbo.renderStreamMessage(await response.text());
  } catch (_error) {
    // A dropped poll is retried on the next tick.
  } finally {
    inFlight = false;
  }
}

function cleanName(value) {
  return value.toLowerCase().replace(/^\s+/, "").replace(/^https?:\/\//, "")
    .replace(/\.mcritchie\.studio\/?$/, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+/, "").slice(0, 30);
}

const checkTimers = new WeakMap();

function checkAddress(card) {
  const input = card.querySelector("[data-build-address-input]");
  const status = card.querySelector("[data-build-address-status]");
  const submit = card.querySelector("[data-build-address-submit]");
  if (!input || !status) return;
  const name = input.value.replace(/-+$/, "");
  clearTimeout(checkTimers.get(card));
  const show = (state, text) => {
    status.dataset.state = state;
    status.textContent = text;
    if (submit) submit.disabled = state === "taken";
  };
  if (!name) { show("idle", ""); return; }
  show("checking", "Checking…");
  checkTimers.set(card, setTimeout(async () => {
    try {
      const response = await fetch(`${card.dataset.buildAddress}?subdomain=${encodeURIComponent(name)}`, { headers: { Accept: "application/json" } });
      const data = await response.json();
      if (data.subdomain !== input.value.replace(/-+$/, "")) return;
      show(data.available ? "available" : "taken", data.available ? "Available" : (data.reason || "Not available"));
    } catch (_error) {
      show("idle", "");
    }
  }, 250));
}

document.addEventListener("input", (event) => {
  const nameInput = event.target.closest?.("[data-build-cto-name-input]");
  if (nameInput) {
    nameInput.closest("[data-build-cto]")?.querySelectorAll("[data-build-cto-name]")
      .forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.buildCtoName === nameInput.value.trim())));
    return;
  }
  const input = event.target.closest?.("[data-build-address-input]");
  if (!input) return;
  const cleaned = cleanName(input.value);
  if (cleaned !== input.value) input.value = cleaned;
  checkAddress(input.closest("[data-build-address]"));
});

// A suggestion chip, checked once: a taken name cannot be tapped.
async function checkChip(form) {
  const button = form.querySelector("[data-build-domain-name]");
  if (!button) return;
  try {
    const name = button.dataset.buildDomainName;
    const response = await fetch(`${form.dataset.buildDomainChip}?subdomain=${encodeURIComponent(name)}`, { headers: { Accept: "application/json" } });
    const data = await response.json();
    if (!data.available && button.getAttribute("aria-pressed") !== "true") {
      button.disabled = true;
      button.title = data.reason || "Not available";
    }
  } catch (_error) {
    // Unknown: left tappable; the server checks on the tap.
  }
}

// A portrait pick swaps the preview. It does NOT close the picker: the arrow
// keys move a radio group's pick (and fire change) one step at a time, so a
// keyboard visitor browses with them. A tap on a portrait, Done, Escape (the
// dialog's own) or Enter closes it.
document.addEventListener("change", (event) => {
  const radio = event.target.closest?.("[data-build-portrait-src]");
  if (!radio) return;
  const card = radio.closest("[data-build-cto]");
  const preview = card?.querySelector("[data-build-portrait-preview]");
  if (preview) {
    preview.src = radio.dataset.buildPortraitSrc;
    const label = radio.closest("label")?.title;
    if (label) preview.alt = `${label} portrait`;
  }
});

// Enter on a portrait closes the picker instead of submitting the CTO form.
document.addEventListener("keydown", (event) => {
  if (event.key !== "Enter" || !event.target.closest?.("[data-build-portrait-src]")) return;
  event.preventDefault();
  event.target.closest("[data-build-portrait-dialog]")?.close();
});

// The theme card's Dark / Light choice, per card (its turn's id). The server
// draws every card in dark, so a re-render (the tap's own stream, a poll)
// would put it back; each re-render applies the remembered mode again.
const themeModes = new Map();

function showThemeMode(card, chosen) {
  card.dataset.mode = chosen;
  card.querySelectorAll("[data-build-theme-mode]").forEach((b) => b.setAttribute("aria-pressed", String(b.dataset.buildThemeMode === chosen)));
  card.querySelectorAll("[data-build-theme-preview]").forEach((p) => { p.hidden = p.dataset.buildThemePreview !== chosen; });
}

function themeKey(card) {
  return card.closest("[data-build-turn]")?.id || null;
}

function restoreThemeModes() {
  document.querySelectorAll("[data-build-theme]").forEach((card) => {
    const chosen = themeModes.get(themeKey(card));
    if (chosen && card.dataset.mode !== chosen) showThemeMode(card, chosen);
  });
}

document.addEventListener("click", (event) => {
  const open = event.target.closest?.("[data-build-portrait-open]");
  if (open) {
    open.closest("[data-build-cto]")?.querySelector("[data-build-portrait-dialog]")?.showModal();
    return;
  }
  const close = event.target.closest?.("[data-build-portrait-close]");
  if (close) { close.closest("dialog")?.close(); return; }
  // A tap on a portrait's picture (the label) closes the picker. The arrow
  // keys also fire click, but on the radio itself, so they never land here.
  const portrait = event.target.closest?.("[data-build-portrait-dialog] label");
  if (portrait && !event.target.matches("input")) {
    portrait.closest("dialog")?.close();
    return;
  }
  const ctoName = event.target.closest?.("[data-build-cto-name]");
  if (ctoName) {
    const card = ctoName.closest("[data-build-cto]");
    const input = card?.querySelector("[data-build-cto-name-input]");
    if (input) { input.value = ctoName.dataset.buildCtoName; input.focus(); }
    card?.querySelectorAll("[data-build-cto-name]").forEach((b) => b.setAttribute("aria-pressed", String(b === ctoName)));
    return;
  }
  const mode = event.target.closest?.("[data-build-theme-mode]");
  if (mode) {
    const card = mode.closest("[data-build-theme]");
    const chosen = mode.dataset.buildThemeMode;
    const key = themeKey(card);
    if (key) themeModes.set(key, chosen);
    showThemeMode(card, chosen);
    return;
  }
  const signIn = event.target.closest?.("[data-build-sign-in]");
  if (signIn && window.Alpine?.store("modals")) {
    window.Alpine.store("modals").open("auth", JSON.parse(signIn.dataset.buildSignIn));
  }
});

// A card already on the page (or one a poll or a tap brings) checks its names once.
function checkNewCards() {
  document.querySelectorAll("[data-build-address]:not([data-build-address-checked])").forEach((card) => {
    card.dataset.buildAddressChecked = "true";
    checkAddress(card);
  });
  document.querySelectorAll("[data-build-domain-chip]:not([data-build-address-checked])").forEach((form) => {
    form.dataset.buildAddressChecked = "true";
    checkChip(form);
  });
}

document.addEventListener("turbo:load", () => { waitingSince = null; checkNewCards(); restoreThemeModes(); });
document.addEventListener("turbo:before-stream-render", (event) => {
  const original = event.detail.render;
  event.detail.render = async (stream) => {
    await original(stream);
    checkNewCards();
    restoreThemeModes();
  };
});
setInterval(tick, 500);
