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
import { clockFmt, shortFmt, agoFmt, windowState, countdown } from "board/ticker";

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

function tick() {
  const now = Math.floor(Date.now() / 1000);
  document.querySelectorAll("[data-release-ticker]").forEach((el) => {
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
