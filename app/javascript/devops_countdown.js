// The app chat status card's live pill countdown (agent_chats/_devops_stages;
// task live-build-countdown): a step with a real start reads "05:48" to its
// expected finish (AppDevopsStages::Eta, THE COUNTDOWN), and this ticks it once
// a second. Delegated: every tick reads the page's [data-devops-countdown] spans
// afresh, so a status frame reloaded over AppDevopsChannel keeps ticking; inert
// where none is. Text only, so it updates under reduced motion too.
//
// The /deployments DevOps card's hero (task devops-card-counts-down-to-ship) is the
// same span with data-countdown-over: it counts down to the release's estimated
// landing (Release::Flow#estimate) and, past it, counts the overrun UP instead of
// holding — "+12m over", data-eta-kind="over" — so a late release says how late.

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

// "12m", "1h 5m", "<1m" — the overrun in the page's stage vocabulary. Matches
// ApplicationHelper#precise_stage_duration under a day, which paints the first value.
export function overLabel(seconds) {
  const total = Math.floor(seconds);
  if (!Number.isFinite(total) || total < 60) return "<1m";
  if (total < 3600) return Math.floor(total / 60) + "m";
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  return minutes === 0 ? hours + "h" : hours + "h " + minutes + "m";
}

// Rewrites every countdown span from its data-deadline (ISO 8601). A span whose
// deadline has passed is marked data-eta-kind="long", as the server marks it; one
// carrying data-countdown-over reads "+Xm over" and is marked "over" instead.
export function tick(root, nowMs) {
  root.querySelectorAll("[data-devops-countdown]").forEach((el) => {
    const at = Date.parse(el.dataset.deadline);
    if (!Number.isFinite(at)) return;
    const left = (at - nowMs) / 1000;
    const late = left < 1;
    const counting = el.dataset.countdownOver !== undefined;
    const text = late && counting ? "+" + overLabel(-left) + " over" : countdownClock(left);
    if (el.textContent !== text) el.textContent = text;
    // A hero span's kind follows its clock BOTH ways — "left" while time is left,
    // "over" past it — so the warning ink never outlives the overrun (a clock moved
    // back, a tab woken). The pill keeps its one-way "long" mark.
    const kind = counting ? (late ? "over" : "left") : (late ? "long" : null);
    if (kind && el.dataset.etaKind !== kind) el.dataset.etaKind = kind;
  });
}

if (typeof document !== "undefined" && typeof window !== "undefined" && !window.__devopsCountdownArmed) {
  window.__devopsCountdownArmed = true;
  const run = () => tick(document, Date.now());
  document.addEventListener("turbo:load", run);
  document.addEventListener("turbo:frame-load", run);
  window.setInterval(run, 1000);
}
