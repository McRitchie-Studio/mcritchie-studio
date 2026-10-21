// The app chat status card's live pill countdown (agent_chats/_devops_stages;
// task live-build-countdown): a step with a real start reads "05:48" to its
// expected finish (AppDevopsStages::Eta, THE COUNTDOWN), and this ticks it once
// a second. Delegated: every tick reads the page's [data-devops-countdown] spans
// afresh, so a status frame reloaded over AppDevopsChannel keeps ticking; inert
// where none is. Text only, so it updates under reduced motion too.

export const ANY_MINUTE = "Any minute now";

// "05:48", "1:02:03" from an hour up, ANY_MINUTE at or past zero, never a
// negative. Matches AppDevopsStages::Eta.clock; the server paints the first value.
export function countdownClock(seconds) {
  const total = Math.floor(seconds);
  if (!Number.isFinite(total) || total <= 0) return ANY_MINUTE;
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  const two = (n) => String(n).padStart(2, "0");
  return hours > 0 ? hours + ":" + two(minutes) + ":" + two(secs) : two(minutes) + ":" + two(secs);
}

// Rewrites every countdown span from its data-deadline (ISO 8601). A span whose
// deadline has passed is marked data-eta-kind="long", as the server marks it.
export function tick(root, nowMs) {
  root.querySelectorAll("[data-devops-countdown]").forEach((el) => {
    const at = Date.parse(el.dataset.deadline);
    if (!Number.isFinite(at)) return;
    const left = (at - nowMs) / 1000;
    const text = countdownClock(left);
    if (el.textContent !== text) el.textContent = text;
    if (left < 1 && el.dataset.etaKind !== "long") el.dataset.etaKind = "long";
  });
}

if (typeof document !== "undefined" && typeof window !== "undefined" && !window.__devopsCountdownArmed) {
  window.__devopsCountdownArmed = true;
  const run = () => tick(document, Date.now());
  document.addEventListener("turbo:load", run);
  document.addEventListener("turbo:frame-load", run);
  window.setInterval(run, 1000);
}
