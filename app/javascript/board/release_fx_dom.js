// The Last Release fx router, wired to the page. Importing this module installs
// window.ReleaseFx once; board/live_fx_dom imports it and hands it every
// #last-release swap. The decisions live in board/release_fx (pure, node-tested);
// the .lbfx-fresh-deploy CSS stays in tasks/_release_fx_router, rendered with the
// same window the card publishes as data-fresh-window-ms.
import {
  CARD_ID, SWAP_GLOW_MS, FRESH_DEPLOY_STYLE_PROPS, FRESH_CLEANUP_SLACK_MS, SILENT_KINDS,
  HANDLER_CLAIMS, claimingKind, freshDeployWindow
} from "board/release_fx";
import { hexToRgb } from "board/colors";

function install() {
  // A deploy just landed: re-enter the glow at the phase the wall clock says it is at
  // (a negative animation-delay), or clear it once the window has closed.
  function freshDeployGlow(card) {
    if (!card) return false;
    const fresh = freshDeployWindow({
      freshDeploy: card.dataset.freshDeploy,
      shippedAtMs: card.dataset.shippedAtMs,
      windowMs: card.dataset.freshWindowMs,
      now: Date.now()
    });
    if (fresh.state === "off") return false;
    if (fresh.state === "expired") {
      clearFreshDeployGlow(card);
      return false;
    }
    if (card.dataset.freshDeployCleanup === "true") return true;

    card.style.setProperty("--lbfx-fresh-delay", "-" + fresh.elapsed + "ms");
    card.classList.remove("opacity-75");
    card.classList.add("studio-border-glow", "release-fresh-glow");
    card.classList.remove("lbfx-fresh-deploy");
    void card.offsetWidth;
    card.classList.add("lbfx-fresh-deploy");
    card.dataset.freshDeployCleanup = "true";
    setTimeout(() => clearFreshDeployGlow(card), fresh.remaining + FRESH_CLEANUP_SLACK_MS);
    return true;
  }

  function clearFreshDeployGlow(card) {
    if (!card) return;
    card.classList.remove("lbfx-fresh-deploy", "studio-border-glow", "release-fresh-glow");
    card.classList.add("opacity-75");
    card.dataset.freshDeploy = "false";
    delete card.dataset.freshDeployCleanup;
    FRESH_DEPLOY_STYLE_PROPS.forEach((prop) => card.style.removeProperty(prop));
    if (!card.getAttribute("style")) card.removeAttribute("style");
  }

  // A DIFFERENT release now occupies the slot: one subtle glow.
  function swapGlow(card) {
    const rgb = hexToRgb(card.dataset.glow || "");
    if (rgb) card.style.setProperty("--lbfx-glow", rgb);
    card.classList.add("lbfx-glow");
    setTimeout(() => {
      card.classList.remove("lbfx-glow");
      card.style.removeProperty("--lbfx-glow");
    }, SWAP_GLOW_MS);
    return true;
  }

  const PLAYERS = { "deploy.landed": freshDeployGlow, "release.swapped": swapGlow };
  const HANDLERS = HANDLER_CLAIMS.map((row) => ({ ...row, play: PLAYERS[row.kind] }));

  // Everything worth remembering about the slot BEFORE Turbo replaces it.
  function snapshot(card) {
    if (!card) return null;
    return { signature: card.dataset.cardSignature || "" };
  }

  // Route one render of the card. Returns the kind that played, or null for silence.
  function route(card, before, declared) {
    if (!card) return null;
    const kind = claimingKind({
      freshDeploy: card.dataset.freshDeploy,
      before: before,
      signature: card.dataset.cardSignature || "",
      declared: declared
    });
    if (!kind) return null;
    return PLAYERS[kind](card) ? kind : null;
  }

  // Re-enter any resumable fx still inside its window. Runs on page load and Turbo
  // navigation, where there is no swap to route: the glow belongs to the release's
  // wall clock, not to the render that happened to show it.
  function resume(root) {
    const scope = root && root.querySelectorAll ? root : document;
    scope.querySelectorAll("#" + CARD_ID).forEach((card) => route(card, null, null));
  }

  function scheduleResume() {
    requestAnimationFrame(() => resume(document));
  }

  document.addEventListener("turbo:load", scheduleResume);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", scheduleResume, { once: true });
  } else {
    scheduleResume();
  }

  return { CARD_ID, snapshot, route, resume, HANDLERS, SILENT_KINDS };
}

window.ReleaseFx = window.ReleaseFx || install();
