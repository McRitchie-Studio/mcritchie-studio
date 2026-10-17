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
// Also two delegated behaviours a card may need however it arrived (on load or
// in a poll), so the templates carry no inline script:
//
//   - the address card ([data-build-address]): the field is cleaned as it is
//     typed (the server's AppRequest.normalize_subdomain, done again here), a
//     suggestion fills it, and /build/check answers live; a name we KNOW is
//     refused disables the button (the server re-checks on the tap regardless);
//   - Build my app signed out ([data-build-sign-in]): opens the standard
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
  card.querySelectorAll("[data-build-address-pick]").forEach((pick) => {
    pick.setAttribute("aria-pressed", String(pick.dataset.buildAddressPick === input.value));
  });
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
  const input = event.target.closest?.("[data-build-address-input]");
  if (!input) return;
  const cleaned = cleanName(input.value);
  if (cleaned !== input.value) input.value = cleaned;
  checkAddress(input.closest("[data-build-address]"));
});

document.addEventListener("click", (event) => {
  const pick = event.target.closest?.("[data-build-address-pick]");
  if (pick) {
    const card = pick.closest("[data-build-address]");
    const input = card?.querySelector("[data-build-address-input]");
    if (input) { input.value = pick.dataset.buildAddressPick; checkAddress(card); }
    return;
  }
  const signIn = event.target.closest?.("[data-build-sign-in]");
  if (signIn && window.Alpine?.store("modals")) {
    window.Alpine.store("modals").open("auth", JSON.parse(signIn.dataset.buildSignIn));
  }
});

// A card already on the page (or one a poll brings) checks its prefilled name once.
function checkNewCards() {
  document.querySelectorAll("[data-build-address]:not([data-build-address-checked])").forEach((card) => {
    card.dataset.buildAddressChecked = "true";
    checkAddress(card);
  });
}

document.addEventListener("turbo:load", () => { waitingSince = null; checkNewCards(); });
document.addEventListener("turbo:before-stream-render", (event) => {
  const original = event.detail.render;
  event.detail.render = async (stream) => {
    await original(stream);
    checkNewCards();
  };
});
setInterval(tick, 500);
