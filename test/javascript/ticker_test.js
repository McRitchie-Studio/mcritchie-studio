// [unit] The elapsed ticker's text (board/ticker). Each formatter matches its server
// twin, so the expected strings here are the ones the Ruby helpers render.
import { test } from "node:test";
import assert from "node:assert/strict";

import { clockFmt, shortFmt, windowFmt, agoFmt, windowState, countdown, localCheckStalled } from "board/ticker";

test("the clock reads seconds, then minutes with padded seconds, then hours with padded minutes", () => {
  assert.equal(clockFmt(0), "0s");
  assert.equal(clockFmt(59), "59s");
  assert.equal(clockFmt(60), "1m 00s");
  assert.equal(clockFmt(425), "7m 05s");
  assert.equal(clockFmt(3599), "59m 59s");
  assert.equal(clockFmt(3600), "1h 00m");
  assert.equal(clockFmt(7380), "2h 03m");
});

test("the short clock keeps one unit and climbs to days", () => {
  assert.equal(shortFmt(47), "47s");
  assert.equal(shortFmt(60), "1m");
  assert.equal(shortFmt(3599), "59m");
  assert.equal(shortFmt(3600), "1h");
  assert.equal(shortFmt(86_399), "23h");
  assert.equal(shortFmt(86_400), "1d");
});

test("the window clock pads both sides", () => {
  assert.equal(windowFmt(5), "00:05");
  assert.equal(windowFmt(605), "10:05");
});

test("the ago clock matches the server's X ago shape", () => {
  assert.equal(agoFmt(45), "45s ago");
  assert.equal(agoFmt(240), "4m ago");
  assert.equal(agoFmt(3900), "1h 05m ago");
});

test("a window is open with mm:ss, urgent in its last minute, then lapsed", () => {
  assert.deepEqual(windowState(1000, 900), { state: "open", text: "01:40", urgent: false });
  assert.deepEqual(windowState(1000, 940), { state: "open", text: "01:00", urgent: true });
  assert.deepEqual(windowState(1000, 1000), { state: "lapsed" });
  assert.deepEqual(windowState(1000, 1200), { state: "lapsed" });
});

test("a countdown forecasts with ~ and turns negative after the average", () => {
  assert.deepEqual(countdown(60, 300, "Average QA"), {
    overrun: false, text: "~4m 00s", title: "Average QA: 5m 00s · elapsed 1m 00s · 4m 00s left"
  });
  const over = countdown(330, 300);
  assert.equal(over.overrun, true);
  assert.equal(over.text, "-30s");
  assert.equal(over.title, "Historical average: 5m 00s · elapsed 5m 30s · over by 30s");
});

test("a local check stalls only while running and only past its heartbeat deadline", () => {
  assert.equal(localCheckStalled("running", "100", 101), true);
  assert.equal(localCheckStalled("running", "100", 100), false);
  assert.equal(localCheckStalled("passed", "100", 500), false);
  assert.equal(localCheckStalled("running", "", 500), false);
});
