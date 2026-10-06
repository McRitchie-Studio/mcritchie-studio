// The install-once elapsed ticker, wired to the page. Every second it re-queries the
// DOM for [data-release-ticker] spans, so a Turbo-Streamed card swap is picked up
// with no re-wiring. tasks/_release_ticker imports it; the text comes from
// board/ticker (pure, node-tested).
//
// A span's data-mode picks its clock:
//   (none)      the Next Release in-progress timer: data-prefix + "7m 05s" since data-since
//   short       the CI meter's single-unit clock ("47s", "7m")
//   ago         time since a tracker stage started ("4m ago"), titled once
//   countdown   data-since against data-average-seconds, negative after overrun
//   window      the operator-window chip (tasks/_window_chip): "mm:ss" to data-ends-at,
//               then data-lapsed-label; flips the chip's data-window-state and marks
//               data-window-urgent inside the last minute
import { clockFmt, shortFmt, agoFmt, windowState, countdown, localCheckStalled } from "board/ticker";

function tickWindow(el, now) {
  const endsAt = parseInt(el.dataset.endsAt || "0", 10);
  if (!endsAt) return;
  const chip = el.closest("[data-window-state]");
  const clock = windowState(endsAt, now);
  if (clock.state === "lapsed") {
    el.textContent = el.dataset.lapsedLabel || "lapsed";
    if (chip) {
      chip.dataset.windowState = "lapsed";
      delete chip.dataset.windowUrgent;
    }
    return;
  }
  el.textContent = clock.text;
  if (!chip) return;
  chip.dataset.windowState = "open";
  if (clock.urgent) chip.dataset.windowUrgent = "true";
  else delete chip.dataset.windowUrgent;
}

// Freeze a killed local check at its LAST HEARTBEAT, not at this browser's
// observation time.
function stallQuietLocalCheck(el, now) {
  const root = el.closest("[data-local-check-stale-at]");
  if (!root || !localCheckStalled(root.dataset.localCheckState, root.dataset.localCheckStaleAt, now)) return false;

  root.dataset.localCheckState = "stalled";
  root.setAttribute("aria-label", "Local check stalled — heartbeat stopped");
  root.title = "Local check stalled — heartbeat stopped";

  const spinner = root.querySelector("[data-test$='-spinner']");
  const warning = root.querySelector("[data-test$='-stalled-icon']");
  if (spinner) {
    spinner.hidden = true;
    spinner.classList.add("hidden");
  }
  if (warning) {
    warning.hidden = false;
    warning.classList.remove("hidden");
  }

  const label = root.querySelector("[data-test$='-label']");
  if (label) label.textContent = label.dataset.stalledLabel || "Local check — stalled";
  root.querySelectorAll("[data-local-check-tone]").forEach((node) => {
    node.classList.remove("text-primary");
    node.classList.add("text-warning-ink");
  });

  el.removeAttribute("data-release-ticker");
  el.dataset.localCheckClock = "stalled";
  el.textContent = el.dataset.localCheckFreezeLabel || shortFmt(
    parseInt(el.dataset.localCheckFreezeSeconds || "0", 10)
  );
  el.title = "Local check clock frozen at the last heartbeat";
  return true;
}

function tick() {
  const now = Math.floor(Date.now() / 1000);
  document.querySelectorAll("[data-release-ticker]").forEach((el) => {
    if (stallQuietLocalCheck(el, now)) return;
    if (el.dataset.mode === "window") return tickWindow(el, now);
    const since = parseInt(el.dataset.since || "0", 10);
    if (!since) return;
    const secs = Math.max(0, now - since);
    if (el.dataset.mode === "countdown") {
      const average = parseInt(el.dataset.averageSeconds || "0", 10);
      if (!average) return;
      const clock = countdown(secs, average, el.dataset.averageTitle);
      el.dataset.overrun = clock.overrun ? "true" : "false";
      el.textContent = clock.text;
      el.title = clock.title;
    } else if (el.dataset.mode === "short") {
      el.textContent = shortFmt(secs);
    } else if (el.dataset.mode === "ago") {
      el.textContent = agoFmt(secs);
      if (!el.dataset.titled) {
        el.dataset.titled = "1";
        const startedAt = new Date(since * 1000).toLocaleString([], {
          month: "short", day: "numeric", hour: "numeric", minute: "2-digit"
        });
        el.title = "Started " + startedAt +
          (el.dataset.took ? " · took " + el.dataset.took : "");
      }
    } else {
      el.textContent = (el.dataset.prefix || "") + clockFmt(secs);
    }
  });
}

if (!window.__releaseTicker) {
  window.__releaseTicker = true;
  setInterval(tick, 1000);
  tick();
}
