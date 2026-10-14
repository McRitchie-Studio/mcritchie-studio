// The /dreams status filter: All, Approved or Proposed.
//
// Usage (app/views/dreams/index.html.erb):
//   <section data-dreams-filter="all">
//     <a data-dreams-filter-button="proposed" href="/dreams?status=proposed">…</a>
//     <div data-statuses="approved proposed"> … stage group … </div>
//     <details data-status="proposed"> … dream card … </details>
//   </section>
//
// The page is served whole and the links work with JavaScript off (the server
// reads ?status= to choose the starting filter). Here a click filters in place:
// a card shows when its status matches, a stage group when any of its cards does,
// and the address bar keeps the choice.

const ACTIVE = ["bg-primary", "text-white"];
const IDLE = ["text-secondary", "hover:text-heading"];

// True when an element with these space-separated statuses shows under `filter`.
export function matches(statuses, filter) {
  if (filter === "all") return true;
  return String(statuses || "").split(" ").includes(filter);
}

export function applyFilter(root, filter) {
  root.setAttribute("data-dreams-filter", filter);
  root.querySelectorAll("[data-status]").forEach((card) => {
    card.hidden = !matches(card.getAttribute("data-status"), filter);
  });
  root.querySelectorAll("[data-statuses]").forEach((group) => {
    group.hidden = !matches(group.getAttribute("data-statuses"), filter);
  });
  root.querySelectorAll("[data-dreams-filter-button]").forEach((button) => {
    const on = button.getAttribute("data-dreams-filter-button") === filter;
    button.setAttribute("aria-pressed", on ? "true" : "false");
    ACTIVE.forEach((name) => button.classList.toggle(name, on));
    IDLE.forEach((name) => button.classList.toggle(name, !on));
  });
}

const installed = new WeakSet();

export function installDreamsFilter(doc = document) {
  doc.querySelectorAll("[data-dreams-filter]").forEach((root) => {
    if (installed.has(root)) return;
    installed.add(root);
    root.querySelectorAll("[data-dreams-filter-button]").forEach((button) => {
      button.addEventListener("click", (event) => {
        event.preventDefault();
        applyFilter(root, button.getAttribute("data-dreams-filter-button"));
        if (typeof history !== "undefined") history.replaceState(history.state, "", button.href);
      });
    });
    applyFilter(root, root.getAttribute("data-dreams-filter") || "all");
  });
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:load", () => installDreamsFilter());
  if (document.readyState !== "loading") installDreamsFilter();
}
