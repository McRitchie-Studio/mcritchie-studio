// The Last Release fx router's decisions, with no DOM. board/release_fx_dom wires
// them to the #last-release card on /deployments; test/javascript/release_fx_test.js
// holds them.
//
// WHY A ROUTER. The rest of the board effects are a DOM diff: the server broadcasts a
// blind "replace this slot" and the client infers what happened. For #last-release
// that inference defaulted to celebrating, and DeploymentsBroadcaster re-broadcasts
// the release modules on every CI upsert, so byte-identical re-renders threw confetti.
//
// THE INVERSION. Nothing plays unless a handler CLAIMS the card. No claim is the
// default, and it makes a byte-identical re-render silent by construction.
//
// THE SHAPE. Chain of responsibility: each handler reads the same context and decides
// for itself; the first to claim plays, alone. That "alone" is the anti-stampede
// rule: a ship and a seal landing in one beat animate once.
//
// THE INPUTS, in falling authority:
//   1. `data-fx` on the <turbo-stream>: the server DECLARING why it broadcast
//      (DeploymentsBroadcaster.release_modules(fx:)). A kind in SILENT_KINDS
//      short-circuits to silence.
//   2. `data-*` on the card: data-fresh-deploy, data-shipped-at-ms and
//      data-fresh-window-ms make the deploy glow a resumable wall-clock window.
//   3. The pre-swap snapshot: data-card-signature, read BEFORE Turbo destroys the
//      old node.

export const CARD_ID = "last-release";
export const SWAP_GLOW_MS = 850; // the .lbfx-glow animation in tasks/_deployments_live_fx

// Everything the fresh glow writes inline, so clearing it leaves no residue.
export const FRESH_DEPLOY_STYLE_PROPS = [
  "--lbfx-fresh-delay",
  "--studio-border-glow-offset",
  "--studio-border-glow-duration",
  "--studio-border-glow-angle",
  "--task-card-glow-color",
  "--task-card-glow-color-a",
  "--task-card-glow-color-b",
  "--task-card-glow-border-color",
  "--task-card-glow-shadow",
  "border-color",
  "box-shadow"
];

// How long after the window closes the cleanup runs, so the CSS fade has landed.
export const FRESH_CLEANUP_SLACK_MS = 150;

// Declared kinds that mean "I re-broadcast, but nothing about THIS card moved." A
// short-circuit, not a handler. `ci.progress` stays declared and honoured even though
// .ci_progress no longer pushes this slot, so the silence survives a future caller.
export const SILENT_KINDS = new Set(["ci.progress"]);

// The registry, in priority order. Each row's claims(ctx) says whether it may play;
// ctx is { freshDeploy, before, signature, declared }. Adding an animation means
// adding a row here (and its player in board/release_fx_dom). A card no row claims
// stays still.
export const HANDLER_CLAIMS = [
  // A deploy just landed in this slot. A WINDOW, not an instant: claimed for the
  // whole window after shipped_at and re-entered (not restarted) on every render.
  { kind: "deploy.landed", resumable: true, claims: (ctx) => ctx.freshDeploy === "true" },
  // A DIFFERENT release now occupies the slot: one subtle glow.
  { kind: "release.swapped", resumable: false, claims: (ctx) => !!ctx.before && ctx.signature !== ctx.before.signature }
];

// The kind that claims this render, or null for silence. `before` is null on a plain
// page load, which is right: the resumable handler still claims a live window, and
// the diff-based one cannot claim without a diff.
export function claimingKind(ctx, handlers = HANDLER_CLAIMS) {
  if (SILENT_KINDS.has(ctx.declared)) return null;
  for (const handler of handlers) {
    if (handler.claims(ctx)) return handler.kind;
  }
  return null;
}

// Where the fresh-deploy window stands for a card at `now`. The glow is measured from
// shipped_at by wall clock, so a reload mid-window rejoins at the right PHASE.
//   { state: "off" }               the card is not fresh
//   { state: "expired", elapsed }  the window has closed: clear the glow
//   { state: "live", elapsed, remaining }
// A shipped time of zero or less counts as just shipped. A missing window counts as
// zero, which closes it: the router's default is silence.
export function freshDeployWindow({ freshDeploy, shippedAtMs, windowMs, now }) {
  if (freshDeploy !== "true") return { state: "off" };
  const shippedAt = Number(shippedAtMs || 0);
  const elapsed = shippedAt > 0 ? Math.max(0, now - shippedAt) : 0;
  const window = Number(windowMs) || 0;
  if (elapsed >= window) return { state: "expired", elapsed };
  return { state: "live", elapsed, remaining: window - elapsed };
}
