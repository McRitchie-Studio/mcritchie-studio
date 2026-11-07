// The /deployments Workflows SIDEBAR's hand-turned wheel (tasks/_heartbeats_card,
// :detail; task workflows-panel-agent-links): one soul shown at a time, Previous /
// Next wrapping at both ends, the dots jumping. Delegated on the document, so a
// Turbo visit needs no rebinding; inert where no [data-workflows-cycle] is.
//
// It also opens the sidebar ON THE CARD'S SOUL: a click on the Workflows summary
// card hands the soul in frame to the sidebar. A click, not a watch: the card's
// wheel keeps turning while the sidebar is open, and must not pull it away.

// The index `delta` steps from `index`, wrapping both ways through `count`.
export function stepIndex(index, delta, count) {
  if (!count) return 0;
  return (((index + delta) % count) + count) % count;
}

function agentsOf(card) {
  return (card.dataset.agents || "").split(",").filter(Boolean);
}

// Shows `slug` in `card`; an unknown slug leaves the operator's place alone.
export function showAgent(card, slug) {
  const agents = agentsOf(card);
  const index = agents.indexOf(slug);
  if (index < 0) return;
  card.dataset.activeAgent = slug;
  card.querySelectorAll("[data-workflows-soul]").forEach((soul) => {
    soul.hidden = soul.dataset.agent !== slug;
  });
  card.querySelectorAll("[data-workflows-go]").forEach((dot) => {
    const on = dot.dataset.workflowsGo === slug;
    dot.dataset.active = String(on);
    dot.setAttribute("aria-selected", String(on));
  });
  const position = card.querySelector("[data-workflows-position]");
  if (position) position.textContent = String(index + 1);
}

function step(card, delta) {
  const agents = agentsOf(card);
  const index = Math.max(agents.indexOf(card.dataset.activeAgent), 0);
  showAgent(card, agents[stepIndex(index, delta, agents.length)]);
}

if (typeof document !== "undefined" && typeof window !== "undefined" && !window.__workflowsCycleArmed) {
  window.__workflowsCycleArmed = true;
  document.addEventListener("click", (event) => {
    const target = event.target instanceof Element ? event.target : null;
    if (!target) return;
    const stepper = target.closest("[data-workflows-step]");
    if (stepper) {
      const card = stepper.closest("[data-workflows-cycle]");
      if (card) step(card, Number(stepper.dataset.workflowsStep));
      return;
    }
    const dot = target.closest("[data-workflows-go]");
    if (dot) {
      const card = dot.closest("[data-workflows-cycle]");
      if (card) showAgent(card, dot.dataset.workflowsGo);
      return;
    }
    const summary = target.closest("#agents-summary-card");
    if (summary) {
      // After Alpine's effects flush: a dot on the card has just moved its wheel, and
      // the card's data-active-agent follows a microtask later.
      setTimeout(() => {
        const card = document.querySelector("[data-workflows-cycle]");
        if (card && summary.dataset.activeAgent) showAgent(card, summary.dataset.activeAgent);
      }, 0);
    }
  });
}
