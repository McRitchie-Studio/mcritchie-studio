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
// Imported by application.js on every page, once per load; one timer, which
// reads the page fresh on every tick, so a Turbo visit needs no re-binding.
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

document.addEventListener("turbo:load", () => { waitingSince = null; });
setInterval(tick, 500);
