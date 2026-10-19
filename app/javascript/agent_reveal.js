// A NEW agent answer types itself in (task build-chat-reading-flow): on /build
// (the poll's turn replace) and on the agent chats (/applications/:slug/chat, the
// WebChat stream's turn replace). So an answer never just flashes in, and it
// reads as the agent composing.
//
//   - the answer's RENDERED HTML is kept: its text nodes are emptied and filled
//     back in order, so bold, links and lists are there from the first letter
//     (raw markup is never typed). An element shows once its first letter is due
//     (data-agent-unrevealed hides the rest), so a list's bullets never stand
//     empty ahead of their words.
//   - natural speed: about CHARS_PER_SECOND (some 25 characters a 60ms beat),
//     never under MIN_MS and never over MAX_MS however long the answer, timed by
//     the clock, so a slow frame never slows the whole.
//   - the thread stays pinned to its newest line while it types, unless the
//     reader has scrolled up;
//   - what follows the words in the turn (an intake card, .agent-action) waits
//     until the last letter is down, then fades in (app/assets/tailwind/agent_reply.css);
//   - the thinking/typing look hands off to it: the stream that brings the
//     answer is the one that takes the indicator away (build/_turn re-renders the
//     turn without it; agent_chat.js drops a pulse older than the answer).
//   - a screen reader gets the whole answer at once: a hidden plain-words copy
//     of it is read while the visible one types (aria-hidden), and the copy goes
//     at the end, leaving the one answer.
//   - an answer already on the page when it loads (history, a reload, a morph
//     refresh) shows at once, and so does every answer under
//     prefers-reduced-motion.
//
// Imported by application.js on every page, once per load; listeners delegated
// on document, and nothing happens where there is no chat.
const LOG = "[data-cto-chat-scroll]";
const BODY = "[data-agent-reveal]";
const TURN = "[id^='cto-chat-turn-']";
export const CHARS_PER_SECOND = 420;
export const MIN_MS = 450;
export const MAX_MS = 2600;
// A reader this close to the end is following along: keep them there.
const PINNED_PX = 32;

function reducedMotion() {
  return typeof window !== "undefined" && Boolean(window.matchMedia?.("(prefers-reduced-motion: reduce)").matches);
}

// How long an answer of `length` letters takes to type, in ms.
export function revealDuration(length) {
  if (!(length > 0)) return 0;
  return Math.round(Math.min(MAX_MS, Math.max(MIN_MS, (length / CHARS_PER_SECOND) * 1000)));
}

// How many letters are due `elapsed` ms into a reveal of `total` over `duration`.
export function lettersDue(total, elapsed, duration) {
  if (!(duration > 0) || elapsed >= duration) return total;
  return Math.max(0, Math.min(total, Math.ceil((total * Math.max(0, elapsed)) / duration)));
}

// The answer's text, in reading order: each non-blank text node with its words,
// and each element with the letter count where its first word starts. Blank
// text (the newlines between blocks) is left alone and not counted.
export function prepareReveal(root) {
  const items = [];
  const blocks = [];
  let total = 0;
  (function walk(node) {
    node.childNodes?.forEach?.((child) => {
      if (child.nodeType === 3) {
        if (/\S/.test(child.data)) {
          items.push({ node: child, text: child.data });
          total += child.data.length;
        }
      } else if (child.nodeType === 1) {
        blocks.push({ element: child, offset: total });
        walk(child);
      }
    });
  })(root);
  return { items, blocks, total };
}

// The first `shown` letters written in, the rest empty; an element still wholly
// ahead of the cursor hidden.
export function paintReveal(state, shown) {
  let left = shown;
  state.items.forEach(({ node, text }) => {
    const take = Math.max(0, Math.min(text.length, left));
    left -= text.length;
    const value = take >= text.length ? text : text.slice(0, take);
    if (node.data !== value) node.data = value;
  });
  const done = shown >= state.total;
  state.blocks.forEach(({ element, offset }) => {
    const ahead = !done && offset >= shown;
    if (ahead) element.setAttribute("data-agent-unrevealed", "");
    else element.removeAttribute("data-agent-unrevealed");
  });
}

// Types `body` in. Returns a handle whose finish() shows it all at once.
//   now      the clock (ms)
//   frame    schedules the next paint
//   reduced  prefers-reduced-motion: shown at once, nothing touched
//   onPaint  after each paint (the scroll pin); onDone at the end
export function reveal(body, { now = () => performance.now(), frame = (fn) => requestAnimationFrame(fn),
                               reduced = reducedMotion(), onPaint = () => {}, onDone = () => {} } = {}) {
  const state = reduced ? null : prepareReveal(body);
  if (!state || state.total === 0) {
    onDone();
    return { finish() {}, state, duration: 0 };
  }
  const duration = revealDuration(state.total);
  const start = now();
  let finished = false;
  const finish = () => {
    if (finished) return;
    finished = true;
    paintReveal(state, state.total);
    onPaint();
    onDone();
  };
  const tick = () => {
    if (finished) return;
    if (body.isConnected === false) { finished = true; return; }
    const shown = lettersDue(state.total, now() - start, duration);
    if (shown >= state.total) { finish(); return; }
    paintReveal(state, shown);
    onPaint();
    frame(tick);
  };
  paintReveal(state, 0);
  frame(tick);
  return { finish, state, duration };
}

// The turn ids whose answers are already on the page: never typed again.
export function answeredTurns(root) {
  const ids = new Set();
  root?.querySelectorAll?.(BODY).forEach((body) => {
    const id = body.closest?.(TURN)?.id;
    if (id) ids.add(id);
  });
  return ids;
}

// The answers on the page that `seen` does not hold yet, each added to it.
export function newAnswers(root, seen) {
  const fresh = [];
  root?.querySelectorAll?.(BODY).forEach((body) => {
    const id = body.closest?.(TURN)?.id;
    if (!id || seen.has(id)) return;
    seen.add(id);
    fresh.push(body);
  });
  return fresh;
}

// One answer typed in on the page: the screen reader's copy, the turn's waiting
// card, and the scroll pin around reveal().
function typeAnswer(body) {
  const log = body.closest(LOG);
  const turn = body.closest("[data-build-turn]") || body.closest(TURN);
  // The whole answer as plain words for a screen reader (no second set of links
  // or bold to tab to or find twice), read once, while the visible words type.
  const copy = document.createElement("span");
  copy.className = "sr-only";
  copy.setAttribute("data-agent-reveal-copy", "");
  copy.textContent = body.textContent.replace(/\s+/g, " ").trim();
  body.before(copy);
  body.setAttribute("aria-hidden", "true");
  turn?.setAttribute("data-agent-revealing", "");
  const pinned = () => !log || log.scrollHeight - log.clientHeight - log.scrollTop <= PINNED_PX;
  let follow = pinned();
  reveal(body, {
    onPaint() {
      if (follow && log) log.scrollTop = log.scrollHeight;
    },
    onDone() {
      copy.remove();
      body.removeAttribute("aria-hidden");
      turn?.removeAttribute("data-agent-revealing");
      turn?.querySelectorAll(".agent-action").forEach((card) => {
        if (reducedMotion()) return;
        card.classList.add("agent-action-enter");
        card.addEventListener("animationend", () => card.classList.remove("agent-action-enter"), { once: true });
      });
      if (log && (follow || pinned())) requestAnimationFrame(() => { log.scrollTop = log.scrollHeight; });
    },
  });
  // A reader who scrolls up while it types is left where they are.
  log?.addEventListener("wheel", () => { follow = false; }, { once: true, passive: true });
  log?.addEventListener("touchmove", () => { follow = false; }, { once: true, passive: true });
}

if (typeof document !== "undefined") {
  let seen = new Set();
  const remember = () => { seen = answeredTurns(document); };

  document.addEventListener("turbo:before-stream-render", (event) => {
    const original = event.detail.render;
    event.detail.render = async (stream) => {
      await original(stream);
      // Same task as the insert, so the whole answer is never painted first.
      const fresh = newAnswers(document, seen);
      if (reducedMotion()) return;
      fresh.forEach(typeAnswer);
    };
  });

  // Whatever a load or a morph puts on the page is history: shown as it is.
  document.addEventListener("turbo:load", remember);
  document.addEventListener("turbo:morph", remember);
  remember();
}
