// The Build My App launch panel (app/views/build/_launch.html.erb; task
// build-launch-handoff). BuildController#update has ALREADY launched the app
// when this element arrives (a Turbo Stream swaps it in for the agent shell, and
// a replace_url stream moves the address to the CTO's chat, so a reload lands
// there). This only plays the three steps, then visits the chat:
//
//   step 1 active ─2.4s─▶ done, step 2 active ─2.4s─▶ done, step 3 active
//   ─2.4s─▶ done ─0.8s─▶ Turbo.visit(href)                       ≈ 8 seconds
//
// Under prefers-reduced-motion every step shows done at once and the visit
// follows a short pause. The page is kept out of Turbo's snapshot cache, so a
// later visit never previews the panel. A custom element, not an inline script:
// it runs wherever Turbo inserts it, under the strict CSP, and its timers stop
// if the panel leaves the page first (the skip link, Back).
import { Turbo } from "@hotwired/turbo-rails";

export const STEP_MS = 2400;
export const HOLD_MS = 800;
export const REDUCED_MS = 1200;

class BuildLaunch extends HTMLElement {
  connectedCallback() {
    if (this.timers) return;
    this.timers = [];
    Turbo.cache?.exemptPageFromCache?.();
    const steps = [...this.querySelectorAll("[data-test='build-launch-step']")];
    const reduced = window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
    if (reduced) {
      steps.forEach((step) => { step.dataset.state = "done"; });
      this.announce("All set.");
      this.later(REDUCED_MS, () => this.go());
      return;
    }
    steps.forEach((step, index) => {
      this.later(STEP_MS * (index + 1), () => {
        step.dataset.state = "done";
        const next = steps[index + 1];
        if (next) next.dataset.state = "active";
        this.announce(`${step.textContent.trim()}: done.`);
      });
    });
    this.later(STEP_MS * steps.length + HOLD_MS, () => this.go());
  }

  disconnectedCallback() {
    (this.timers || []).forEach((id) => clearTimeout(id));
    this.timers = null;
  }

  later(ms, fn) {
    this.timers.push(setTimeout(fn, ms));
  }

  announce(text) {
    const status = this.querySelector("[data-build-launch-status]");
    if (status) status.textContent = text;
  }

  go() {
    const href = this.dataset.href;
    if (!href || !this.isConnected) return;
    // An advance, never a "replace": the address is already href, and Turbo
    // reads a replace visit to the current path as a page REFRESH, which this
    // page morphs (turbo_refreshes_with :morph) instead of rendering the chat
    // with its view transition. Turbo still writes the history as a replace,
    // because the visit's URL is the one it leaves (Visit#changeHistory).
    Turbo.visit(href);
  }
}

if (!customElements.get("build-launch")) customElements.define("build-launch", BuildLaunch);
