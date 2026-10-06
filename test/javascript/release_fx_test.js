// [unit] The Last Release fx router's decisions (board/release_fx): who claims a
// render, and where the fresh-deploy window stands.
import { test } from "node:test";
import assert from "node:assert/strict";

import { claimingKind, freshDeployWindow, HANDLER_CLAIMS, SILENT_KINDS } from "board/release_fx";

const ctx = (over) => ({ freshDeploy: "false", before: null, signature: "rel-1", declared: null, ...over });

test("a fresh deploy claims the card, even on a plain page load", () => {
  assert.equal(claimingKind(ctx({ freshDeploy: "true" })), "deploy.landed");
});

test("a different release in the slot claims the swap glow", () => {
  assert.equal(claimingKind(ctx({ before: { signature: "rel-0" } })), "release.swapped");
});

test("a byte-identical re-render is silent: nothing claims it", () => {
  assert.equal(claimingKind(ctx({ before: { signature: "rel-1" } })), null);
});

test("without a snapshot the swap glow cannot claim", () => {
  assert.equal(claimingKind(ctx({ before: null, signature: "rel-9" })), null);
});

test("the first claim wins alone: a fresh deploy that also swapped plays once, as the deploy", () => {
  assert.equal(claimingKind(ctx({ freshDeploy: "true", before: { signature: "rel-0" } })), "deploy.landed");
});

test("a declared-silent kind short-circuits every handler", () => {
  assert.ok(SILENT_KINDS.has("ci.progress"));
  assert.equal(claimingKind(ctx({ freshDeploy: "true", before: { signature: "rel-0" }, declared: "ci.progress" })), null);
  assert.equal(claimingKind(ctx({ freshDeploy: "true", declared: "release.sealed" })), "deploy.landed");
});

test("the registry is ordered deploy first, and only the deploy resumes", () => {
  assert.deepEqual(HANDLER_CLAIMS.map((row) => [row.kind, row.resumable]), [["deploy.landed", true], ["release.swapped", false]]);
});

test("the window is live inside its span and reports how far in it is", () => {
  const now = 1_000_000;
  assert.deepEqual(
    freshDeployWindow({ freshDeploy: "true", shippedAtMs: String(now - 15_000), windowMs: "60000", now }),
    { state: "live", elapsed: 15_000, remaining: 45_000 }
  );
});

test("the window expires at its end, so the glow clears", () => {
  const now = 1_000_000;
  assert.equal(freshDeployWindow({ freshDeploy: "true", shippedAtMs: String(now - 60_000), windowMs: "60000", now }).state, "expired");
});

test("a card that is not fresh is off whatever its times say", () => {
  assert.deepEqual(freshDeployWindow({ freshDeploy: "false", shippedAtMs: "1", windowMs: "60000", now: 2 }), { state: "off" });
});

test("a missing ship time counts as just shipped, and a ship time ahead of the clock as zero elapsed", () => {
  assert.deepEqual(freshDeployWindow({ freshDeploy: "true", shippedAtMs: "", windowMs: "20000", now: 5 }), { state: "live", elapsed: 0, remaining: 20_000 });
  assert.equal(freshDeployWindow({ freshDeploy: "true", shippedAtMs: "9000", windowMs: "20000", now: 5000 }).elapsed, 0);
});

test("a missing window closes it: silence is the default", () => {
  assert.equal(freshDeployWindow({ freshDeploy: "true", shippedAtMs: "1", windowMs: undefined, now: 1 }).state, "expired");
});
