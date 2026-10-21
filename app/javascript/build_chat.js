// The /build chat with Ritch (app/views/build/_chat.html.erb; BuildController#turns).
// A signed-out visitor has no /cable socket, so instead of a Turbo stream the
// page POLLS: while any turn is still waiting for Ritch (data-pending="true"), it
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
//   - the domain card ([data-build-address]): the name field is cleaned as it
//     is typed (the server's AppRequest.normalize_subdomain, done again here)
//     and checked live once it changes (the render's own answer comes with
//     the card); a name we KNOW is refused, or the domain already chosen,
//     disables Use Domain (the server re-checks on the tap). The field is the source of truth for the
//     glows (build_domain.js): the chip it matches glows, and a chip tap fills
//     the field without focusing it. The server draws a taken chip disabled;
//   - the CTO card ([data-build-cto]): the avatar or "New image" opens the
//     picker dialog (build/_animal_picker: a set of the animal bank in the
//     app's colours); a pick swaps the preview; "New set" fetches another set
//     from the server and swaps the grid; a tap on an avatar, Done or Enter
//     closes it (the arrow keys only move the pick); a tap on one of Ritch's
//     names fills the name field. The same picker sits in an app's CTO chat
//     (cto_chats/_avatar_picker, a form marked data-build-portrait-save): there
//     a tap, Enter or Space on an avatar, or Done, saves it in place
//     (saveAvatar), and the CTO's "Pick a new avatar" button and the head's
//     portrait ([data-cto-avatar-open]) open it;
//   - the theme card ([data-build-theme]): the Dark / Light toggle swaps every
//     column's preview (a tap on the side already showing flips to the other,
//     build_status.js), and the choice survives the card's re-render;
//   - the CTA glows (cta_glow.js): a theme pick moves Choose Theme's glow to
//     that theme's colours, and a glow scrolled off screen draws nothing;
//
// Imported by application.js on every page, once per load; one timer, which
// reads the page fresh on every tick, and listeners delegated on document, so
// a Turbo visit needs no re-binding.
import { Turbo } from "@hotwired/turbo-rails";
import { pickDomainChip, syncDomainGlow } from "build_domain";
import { syncThemeGlow, watchGlows } from "cta_glow";
import { nextThemeMode } from "build_status";

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
    .replace(/\.mcritchie\.(app|studio)\/?$/, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+/, "").slice(0, 30);
}

const checkTimers = new WeakMap();

function checkAddress(card) {
  const input = card.querySelector("[data-build-address-input]");
  const status = card.querySelector("[data-build-address-status]");
  if (!input || !status) return;
  const name = input.value.replace(/-+$/, "");
  clearTimeout(checkTimers.get(card));
  const show = (state, text) => {
    status.dataset.state = state;
    status.textContent = text;
    syncDomainGlow(card, { taken: state === "taken" });
  };
  // The domain this request already holds needs no check: Use Domain is spent.
  if (!name || name === card.dataset.chosenName) { show("idle", ""); return; }
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

// A portrait pick swaps the preview. It does NOT close the picker: the arrow
// keys move a radio group's pick (and fire change) one step at a time, so a
// keyboard visitor browses with them. A tap on a portrait, Done, Escape (the
// dialog's own) or Enter closes it.
document.addEventListener("change", (event) => {
  // A theme option picked: the glow behind Choose Theme takes its colours.
  const themeCard = event.target.matches?.("input[name='index']") && event.target.closest("[data-build-theme]");
  if (themeCard) { syncThemeGlow(themeCard); return; }
  const radio = event.target.closest?.("[data-build-portrait-option]");
  if (!radio) return;
  showPick(radio);
});

// The preview takes a copy of the picked avatar's own drawing (an inline SVG
// in the app's colours, or an older portrait's <img>).
function showPick(radio) {
  const preview = radio.closest("[data-build-cto]")?.querySelector("[data-build-portrait-preview]");
  const art = radio.nextElementSibling;
  if (!preview || !art) return;
  const copy = art.cloneNode(true);
  // The size is the preview's; .cto-animal stays, as it picks the palette's light or dark set.
  const sized = preview.dataset.artClass || "block h-full w-full rounded-full";
  copy.setAttribute("class", copy.classList.contains("cto-animal") ? `cto-animal ${sized}` : sized);
  preview.replaceChildren(copy);
  preview.dataset.avatar = radio.value;
}

// "New set": the server draws another set (BuildController#cto_animals,
// CtoChatsController#avatars): the current pick leads it, the rest are animals
// not on screen. The pick survives, so a reshuffle never loses it.
async function newAnimalSet(button) {
  const dialog = button.closest("[data-build-portrait-dialog]");
  const grid = dialog?.querySelector("[data-build-portrait-grid]");
  if (!grid || button.disabled) return;
  const params = new URLSearchParams();
  const picked = grid.querySelector("input[name='portrait']:checked");
  if (picked) params.set("keep", picked.value);
  grid.querySelectorAll("input[name='portrait']").forEach((input) => params.append("except[]", input.value));
  button.disabled = true;
  try {
    const response = await fetch(`${button.dataset.buildPortraitShuffle}?${params}`, { headers: { Accept: "text/html" } });
    if (!response.ok) return;
    grid.innerHTML = await response.text();
    grid.querySelector("input[name='portrait']:checked")?.focus();
  } catch (_error) {
    // Offline: the set on screen stays.
  } finally {
    button.disabled = false;
  }
}

// The keyboard in the picker. The arrow keys are the radio group's own: they
// move the pick (and the preview) and keep the picker open. Enter on an
// avatar closes the /build card's picker without submitting the card (its
// Wake Up button saves); in the CTO chat's picker Enter, or Space, SAVES the
// focused avatar (saveAvatar).
document.addEventListener("keydown", (event) => {
  const option = event.target.closest?.("[data-build-portrait-option]");
  if (!option || (event.key !== "Enter" && event.key !== " ")) return;
  const form = option.closest("form[data-build-portrait-save]");
  if (form) {
    event.preventDefault();
    option.checked = true;
    saveAvatar(form);
    return;
  }
  if (event.key !== "Enter") return;
  event.preventDefault();
  option.closest("[data-build-portrait-dialog]")?.close();
});

// The CTO chat's picker (cto_chats/_avatar_picker) saves in place: a fetch to
// CtoChatsController#avatar (JSON), whose answer redraws the head's portrait.
// The picker's status line shows "Saving…" and any refusal (the picker stays
// open to try again); the page's polite live region tells a screen reader the
// result, or that nothing changed. data-current-avatar is the saved one.
function announceAvatar(form, text) {
  const live = form.querySelector("[data-cto-avatar-announce]");
  if (live) { live.textContent = ""; requestAnimationFrame(() => { live.textContent = text; }); }
}

async function saveAvatar(form) {
  const dialog = form.querySelector("[data-build-portrait-dialog]");
  const status = form.querySelector("[data-build-portrait-status]");
  const picked = form.querySelector("input[name='portrait']:checked");
  if (!picked || picked.value === form.dataset.currentAvatar) {
    announceAvatar(form, "Nothing changed.");
    dialog?.close();
    return;
  }
  if (form.dataset.saving === "true") return;
  form.dataset.saving = "true";
  if (status) status.textContent = "Saving…";
  try {
    const token = document.querySelector("meta[name='csrf-token']")?.content;
    const response = await fetch(form.action, {
      method: "POST", body: new FormData(form),
      headers: { Accept: "application/json", ...(token ? { "X-CSRF-Token": token } : {}) }
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || !data.ok) {
      if (status) status.textContent = data.error || "The new look did not save. Try again in a moment.";
      return;
    }
    form.dataset.currentAvatar = data.avatar;
    document.querySelectorAll("[data-cto-avatar-head]").forEach((head) => { head.innerHTML = data.portrait_html; });
    if (status) status.textContent = "";
    announceAvatar(form, data.message);
    dialog?.close();
  } catch (_error) {
    if (status) status.textContent = "The new look did not save. Check your connection and try again.";
  } finally {
    delete form.dataset.saving;
  }
}

// Any other submit of the chat's picker form (an implicit one) saves the same way.
document.addEventListener("submit", (event) => {
  const form = event.target.closest?.("form[data-build-portrait-save]");
  if (!form) return;
  event.preventDefault();
  saveAvatar(form);
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
  const chatOpen = event.target.closest?.("[data-cto-avatar-open]");
  if (chatOpen) {
    document.querySelector("[data-cto-avatar-form] [data-build-portrait-dialog]")?.showModal();
    return;
  }
  const shuffle = event.target.closest?.("[data-build-portrait-shuffle]");
  if (shuffle) { newAnimalSet(shuffle); return; }
  // Done closes the picker; in the CTO chat's it saves the pick first (or
  // says nothing changed).
  const close = event.target.closest?.("[data-build-portrait-close]");
  if (close) {
    const form = close.closest("form[data-build-portrait-save]");
    if (form) saveAvatar(form); else close.closest("dialog")?.close();
    return;
  }
  // A tap on an avatar's picture (the label) closes the picker; in the CTO
  // chat's picker it saves the pick. The arrow keys also fire click, but on the
  // radio itself, so they never land here.
  const portrait = event.target.closest?.("[data-build-portrait-dialog] label");
  if (portrait && !event.target.matches("input")) {
    const form = portrait.closest("form[data-build-portrait-save]");
    const input = portrait.querySelector("input[name='portrait']");
    if (form && input) {
      event.preventDefault();
      input.checked = true;
      saveAvatar(form);
      return;
    }
    portrait.closest("dialog")?.close();
    return;
  }
  const domainChip = event.target.closest?.("[data-build-domain-name]");
  if (domainChip) {
    const card = domainChip.closest("[data-build-address]");
    if (card && pickDomainChip(card, domainChip) !== null) checkAddress(card);
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
    const chosen = nextThemeMode(card.dataset.mode, mode.dataset.buildThemeMode);
    const key = themeKey(card);
    if (key) themeModes.set(key, chosen);
    showThemeMode(card, chosen);
    return;
  }
});

// A card already on the page (or one a poll or a tap brings) draws its glows
// from the answer the server rendered with it (build/cards/_address checks all
// its names once, on the render), so it asks /build/check nothing on arrival;
// only a changed name (typing, a chip tap) is checked live.
function checkNewCards() {
  document.querySelectorAll("[data-build-address]:not([data-build-address-checked])").forEach((card) => {
    card.dataset.buildAddressChecked = "true";
    const status = card.querySelector("[data-build-address-status]");
    syncDomainGlow(card, { taken: status?.dataset.state === "taken" });
  });
}

document.addEventListener("turbo:load", () => { waitingSince = null; checkNewCards(); restoreThemeModes(); watchGlows(); });
document.addEventListener("turbo:before-stream-render", (event) => {
  const original = event.detail.render;
  event.detail.render = async (stream) => {
    await original(stream);
    checkNewCards();
    restoreThemeModes();
    watchGlows();
  };
});
setInterval(tick, 500);
