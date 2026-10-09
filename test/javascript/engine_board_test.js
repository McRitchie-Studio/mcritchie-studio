// [unit] How the board chrome reaches the engine board (board/engine_board), on
// both engines: one whose importmap publishes "studio/board", and one that does not.
import { test } from "node:test";
import assert from "node:assert/strict";

import { engineBoard, importmapPins, installEngineBoard, BOARD_MODULE } from "board/engine_board";

// A document with the given importmap `imports` (null for no importmap tag) and
// the given board sections.
function page({ imports, sections = [] } = {}) {
  const listeners = {};
  return {
    listeners,
    querySelector(selector) {
      if (selector !== 'script[type="importmap"]' || imports === null) return null;
      return { textContent: typeof imports === "string" ? imports : JSON.stringify({ imports }) };
    },
    querySelectorAll() { return sections; },
    addEventListener(name, handler) { (listeners[name] = listeners[name] || []).push(handler); },
  };
}

const PUBLISHED = { application: "/assets/application.js", [BOARD_MODULE]: "/assets/studio/board.js" };
const UNPUBLISHED = { application: "/assets/application.js", "studio/application": "/assets/studio/application.js" };

// An Alpine that counts how often it is asked.
function alpine(scope) {
  const asked = [];
  return { asked, $data(section) { asked.push(section); return scope; } };
}

// A "studio/board" module that counts how often it is imported.
function boardModule(scope) {
  const calls = { imports: 0, asked: [] };
  const importer = () => {
    calls.imports += 1;
    return Promise.resolve({ scopeFor(section) { calls.asked.push(section); return Promise.resolve(scope); } });
  };
  return { calls, importer };
}

test("the importmap says which engine the page has", () => {
  assert.equal(importmapPins(page({ imports: PUBLISHED }), BOARD_MODULE), true);
  assert.equal(importmapPins(page({ imports: UNPUBLISHED }), BOARD_MODULE), false);
  assert.equal(importmapPins(page({ imports: null }), BOARD_MODULE), false, "no importmap pins nothing");
  assert.equal(importmapPins(page({ imports: "{not json" }), BOARD_MODULE), false, "a broken importmap pins nothing");
  assert.equal(importmapPins(page({ imports: { "studio/boards": "/x.js" } }), BOARD_MODULE), false, "a near name is not the pin");
});

test("an engine that publishes its board is reached through scopeFor, and Alpine is never asked", async () => {
  const section = { id: "board" };
  const scope = { toast() {} };
  const engine = boardModule(scope);
  const Alpine = alpine({ wrong: true });
  const reach = engineBoard({ doc: page({ imports: PUBLISHED }), win: { Alpine }, importer: engine.importer });

  assert.equal(reach.published, true);
  assert.equal(reach.scope(section), null, "not resolved yet");
  assert.equal(await reach.ready(section), scope);
  assert.equal(reach.scope(section), scope);
  assert.deepEqual(engine.calls.asked, [section], "one scopeFor for the section, however often it is asked for");
  assert.equal(engine.calls.imports, 1);
  assert.deepEqual(Alpine.asked, [], "Alpine.$data is the other engine's path");
});

test("an engine that publishes no board is read off the element, and nothing is imported", async () => {
  const section = { id: "board" };
  const scope = { toast() {} };
  const engine = boardModule({ wrong: true });
  const Alpine = alpine(scope);
  const reach = engineBoard({ doc: page({ imports: UNPUBLISHED }), win: { Alpine }, importer: engine.importer });

  assert.equal(reach.published, false);
  assert.equal(reach.scope(section), scope, "answered at once");
  assert.equal(await reach.ready(section), scope);
  assert.equal(engine.calls.imports, 0, "an unpinned specifier is never imported");
  assert.deepEqual(Alpine.asked, [section, section]);
});

test("no section, no Alpine and a failed import each answer null and never throw", async () => {
  const section = { id: "board" };
  const published = engineBoard({ doc: page({ imports: PUBLISHED }), win: {}, importer: () => Promise.reject(new Error("offline")) });
  const unpublished = engineBoard({ doc: page({ imports: UNPUBLISHED }), win: {} });
  const complaints = [];
  const consoleError = console.error;
  console.error = (...args) => complaints.push(args);
  try {
    assert.equal(published.scope(null), null);
    assert.equal(await published.ready(null), null);
    assert.equal(await published.ready(section), null, "a failed import resolves null");
    assert.equal(published.scope(section), null);
    assert.equal(unpublished.scope(section), null, "Alpine has not loaded");
    assert.equal(await unpublished.ready(section), null);
  } finally {
    console.error = consoleError;
  }
  assert.equal(complaints.length, 1, "the failed import is reported once");
});

test("installing publishes one reach and primes each board, now and on every Turbo visit", async () => {
  const sections = [{ id: "a" }, { id: "b" }];
  const scope = { toast() {} };
  const Alpine = alpine(scope);
  const doc = page({ imports: UNPUBLISHED, sections });
  const win = { Alpine };

  const reach = installEngineBoard({ win, doc });
  assert.equal(win.HubEngineBoard, reach);
  assert.equal(installEngineBoard({ win, doc }), reach, "a second install is the first");
  assert.equal(doc.listeners["turbo:load"].length, 1);
  assert.deepEqual(Alpine.asked, sections, "primed on install");

  doc.listeners["turbo:load"][0]();
  assert.deepEqual(Alpine.asked, sections.concat(sections), "and again on a Turbo visit");
});
