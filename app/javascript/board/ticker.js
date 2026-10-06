// The elapsed-time ticker's text, with no DOM. board/ticker_dom advances every
// [data-release-ticker] span once a second; test/javascript/ticker_test.js holds
// these. Each formatter MUST match its server twin, or the server-rendered first
// paint and the first tick disagree.

// "47s", "7m 05s", "2h 03m". Matches ApplicationHelper#format_elapsed_clock.
export function clockFmt(secs) {
  if (secs < 60) return secs + "s";
  const m = Math.floor(secs / 60), s = secs % 60;
  if (m < 60) return m + "m " + String(s).padStart(2, "0") + "s";
  const h = Math.floor(m / 60), mm = m % 60;
  return h + "h " + String(mm).padStart(2, "0") + "m";
}

// The CI meter's SINGLE-UNIT ladder: "1s".."59s", "1m".."59m", "1h".."23h", then "1d".
// Matches ApplicationHelper#compact_elapsed_short.
export function shortFmt(secs) {
  if (secs < 60) return secs + "s";
  const m = Math.floor(secs / 60);
  if (m < 60) return m + "m";
  const h = Math.floor(m / 60);
  if (h < 24) return h + "h";
  return Math.floor(h / 24) + "d";
}

// The operator-window clock: "mm:ss" to the end, zero-padded both sides. Matches
// Devops::Windows.format_clock.
export function windowFmt(secs) {
  const m = Math.floor(secs / 60), s = secs % 60;
  return String(m).padStart(2, "0") + ":" + String(s).padStart(2, "0");
}

// Time since a tracker stage STARTED: "45s ago", "4m ago", "1h 05m ago".
export function agoFmt(secs) {
  if (secs < 60) return secs + "s ago";
  const m = Math.floor(secs / 60);
  if (m < 60) return m + "m ago";
  const h = Math.floor(m / 60), mm = m % 60;
  return h + "h " + String(mm).padStart(2, "0") + "m ago";
}

// One operator-window chip at `now` (epoch seconds), against its end (epoch seconds).
//   { state: "lapsed" }                  paint the chip's lapsed label
//   { state: "open", text, urgent }      paint "mm:ss"; urgent inside the last minute
export function windowState(endsAt, now) {
  const left = endsAt - now;
  if (left <= 0) return { state: "lapsed" };
  return { state: "open", text: windowFmt(left), urgent: left <= 60 };
}

// A stage-average countdown after `secs` elapsed. "~" marks the positive prediction
// as a forecast (time remaining), "-" the overrun.
export function countdown(secs, average, averageTitle) {
  const remaining = average - secs;
  const overrun = remaining < 0;
  return {
    overrun,
    text: (overrun ? "-" : "~") + clockFmt(Math.abs(remaining)),
    title: (averageTitle || "Historical average") + ": " + clockFmt(average) +
      " · elapsed " + clockFmt(secs) + " · " +
      (overrun ? "over by " + clockFmt(Math.abs(remaining)) : clockFmt(remaining) + " left")
  };
}
