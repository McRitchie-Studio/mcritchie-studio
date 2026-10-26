// Small /build behaviours of the status card and the theme card (task
// build-cards-quality-pass; Alex McRitchie, 2026-10-19). build_chat.js wires them in.
//
//   - the status card pops again when Build My App is pressed (build_cards.css
//     .build-status-pop); its first pop, when the poll bringing Alex's theme card swaps the
//     heading for it, is agent_shell.js's agent-shell-enter-card;
//   - the theme card's Dark / Light control is a toggle: a tap on the side
//     already showing flips to the other;
//   - "Pick three new themes" ([data-build-ask]) writes its line into the chat
//     box and sends it through the composer's own submit, so it travels the
//     same path as a typed message. A draft the visitor had half typed is held
//     and put back in the box once the send's stream redraws the composer
//     (BuildController#replace_form), so the link never eats it.
//
// Pure where it can be (nextThemeMode, askAgent, restoreDraft take stand-ins),
// so test/javascript/build_status_test.js runs it without a browser.

export const POP_CLASS = "build-status-pop";
export const POP_MS = 700;

// The mode a tap on `clicked` shows when `current` is on screen.
export function nextThemeMode(current, clicked) {
  if (clicked !== current) return clicked;
  return current === "dark" ? "light" : "dark";
}

// Plays the pop on the status card once; a second call restarts it. Under
// reduced motion only its glow plays (build_cards.css).
export function popStatusCard(root = document) {
  const card = root.querySelector?.("[data-build-status-card]");
  if (!card) return false;
  card.classList.remove(POP_CLASS);
  void card.offsetWidth; // restart the animation when it is already running
  card.classList.add(POP_CLASS);
  clearTimeout(card._buildPopTimer);
  card._buildPopTimer = setTimeout(() => card.classList.remove(POP_CLASS), POP_MS + 50);
  return true;
}

// The visitor's half-typed message while an ask posts: { formId, text }, or null.
let heldDraft = null;

export function heldDraftFor() {
  return heldDraft;
}

// Sends `text` through the chat box: fills its field and submits the form the
// way Enter does, so the composer's own send runs. A draft already in the box is
// held for restoreDraft. False with no chat box, or while one send is already
// posting.
export function askAgent(text, root = document) {
  const form = root.querySelector?.("form[data-cto-chat-form]");
  const field = form?.querySelector("textarea");
  if (!form || !field || !text) return false;
  if (form.getAttribute("aria-busy") === "true" || form.dataset.sending === "true") return false;
  const draft = field.value || "";
  heldDraft = draft.trim() === "" ? null : { formId: form.id, text: draft };
  field.value = text;
  field.dispatchEvent?.(new Event("input", { bubbles: true }));
  if (typeof form.requestSubmit === "function") form.requestSubmit(); else form.submit();
  return true;
}

// Puts a held draft back into the redrawn composer's box (with or without an
// error line: the visitor's own words outrank a canned ask they can tap again).
// True when it restored one.
export function restoreDraft(root = document) {
  if (!heldDraft) return false;
  const field = root.querySelector?.("form[data-cto-chat-form]")?.querySelector("textarea");
  if (!field) return false;
  field.value = heldDraft.text;
  heldDraft = null;
  field.dispatchEvent?.(new Event("input", { bubbles: true }));
  return true;
}

if (typeof document !== "undefined") {
  // The send's stream replaces the composer (an empty box, or the ask echoed
  // back with an error): the held draft goes back in after it renders.
  document.addEventListener("turbo:before-stream-render", (event) => {
    if (!heldDraft || event.target.getAttribute("target") !== heldDraft.formId) return;
    const original = event.detail.render;
    event.detail.render = async (element) => {
      await original(element);
      restoreDraft();
    };
  });

  document.addEventListener("click", (event) => {
    const ask = event.target.closest?.("[data-build-ask]");
    if (!ask) return;
    event.preventDefault();
    askAgent(ask.dataset.buildAsk);
  });

  // Build My App pressed: the card celebrates while the launch posts.
  document.addEventListener("turbo:submit-start", (event) => {
    if (event.target.matches?.("[data-build-summary-form]")) popStatusCard();
  });
}
