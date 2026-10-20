// The CTO chat's usage meter countdown (agent_chats/_tokens_bar): under a fifth
// of the month's allowance left, the meter's right side reads "Resets in 3d 4h"
// and this ticks it once a minute. Delegated: every tick reads the page's
// [data-usage-countdown] spans afresh, so a meter re-rendered by an answer
// (AgentMessages::WebChat.broadcast_meter) keeps ticking; inert where none is.

// "Resets in 3d 4h", "Resets in 4h 12m", "Resets in 12m", minutes rounded up.
// Matches AgentUsage.countdown_line; the server paints the first value.
export function countdownLine(seconds) {
  if (seconds <= 0) return "Resetting now";
  const minutes = Math.ceil(seconds / 60);
  const days = Math.floor(minutes / 1440);
  const hours = Math.floor((minutes % 1440) / 60);
  const mins = minutes % 60;
  if (days > 0) return "Resets in " + days + "d " + hours + "h";
  if (hours > 0) return "Resets in " + hours + "h " + mins + "m";
  return "Resets in " + mins + "m";
}

// Rewrites every countdown span from its data-resets-at (epoch seconds).
export function tick(root, nowMs) {
  root.querySelectorAll("[data-usage-countdown]").forEach((el) => {
    const at = Number(el.dataset.resetsAt);
    if (!Number.isFinite(at)) return;
    const text = countdownLine(Math.floor(at - nowMs / 1000));
    if (el.textContent !== text) el.textContent = text;
  });
}

if (typeof document !== "undefined" && typeof window !== "undefined" && !window.__usageCountdownArmed) {
  window.__usageCountdownArmed = true;
  const run = () => tick(document, Date.now());
  document.addEventListener("turbo:load", run);
  window.setInterval(run, 60 * 1000);
}
