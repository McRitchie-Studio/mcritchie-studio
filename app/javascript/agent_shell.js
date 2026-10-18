// The agent shell as the conversation grows (app/views/agent_chats/_shell.html.erb,
// app/assets/tailwind/agent_shell.css; task build-launch-chat-growth). On /build,
// /build/:token and /applications/:slug/chat:
//
//   - the SIZE STEP: data-shell-size moves from full to medium to compact as turns
//     arrive (thresholds on the shell, from AgentShellHelper), and to compact as
//     soon as the thread has to scroll. It only moves forward on a page, so a
//     compacted head never springs back open when the room it freed un-scrolls
//     the thread;
//   - the FIRST MESSAGE's move to /build/<token> (BuildController#create's
//     streams): the thread slides in, the heading and portrait shrink (the size
//     step's CSS transitions), and the gallery slides away before it is removed;
//   - the status card scales in the first time it replaces the heading;
//   - after any stream, the chat box is kept in the window.
//
// Under prefers-reduced-motion the steps and entrances still apply, unanimated
// (the CSS turns the motion off; the gallery goes at once).
//
// Imported by application.js on every page, once per load; listeners delegated on
// document, and nothing happens where there is no shell.
const SHELL = "[data-agent-shell]";
const LOG = "[data-cto-chat-scroll]";
const SIZES = ["full", "medium", "compact"];
const CHAT_ID = "build-chat-page";
const STATUS_ID = "build-checklist";
const GALLERY_ID = "build-gallery";

function reducedMotion() {
  return window.matchMedia?.("(prefers-reduced-motion: reduce)").matches;
}

// The thread's turns: every child of the log but its empty-state line.
function turnCount(shell) {
  const log = shell.querySelector(LOG);
  if (!log) return 0;
  return Array.from(log.children).filter((child) => !/-empty$/.test(child.dataset.test || "")).length;
}

export function sizeFor(shell) {
  const turns = turnCount(shell);
  const mediumAt = Number(shell.dataset.shellMediumAt) || 1;
  const compactAt = Number(shell.dataset.shellCompactAt) || 3;
  const log = shell.querySelector(LOG);
  const scrolling = log && log.scrollHeight > log.clientHeight + 4;
  if (turns >= compactAt || (turns > 0 && scrolling)) return "compact";
  if (turns >= mediumAt) return "medium";
  return "full";
}

export function sizeShell(shell = document.querySelector(SHELL)) {
  if (!shell) return null;
  const now = SIZES.indexOf(shell.dataset.shellSize);
  const next = SIZES.indexOf(sizeFor(shell));
  if (next > now) shell.dataset.shellSize = SIZES[next];
  return shell.dataset.shellSize;
}

function scrollLogToEnd(shell) {
  const log = shell.querySelector(LOG);
  if (log) log.scrollTop = log.scrollHeight;
}

// The chat box in the window: the page scrolls only as far as it must.
function keepComposerInView(shell) {
  const form = shell.querySelector("[data-cto-chat-form], [data-build-first-form]");
  if (!form) return;
  const box = form.getBoundingClientRect();
  if (box.bottom > window.innerHeight || box.top < 0) form.scrollIntoView({ block: "nearest" });
}

function settle() {
  const shell = document.querySelector(SHELL);
  if (!shell) return;
  sizeShell(shell);
  // Once more after the size step's own layout, which can open room or take it.
  requestAnimationFrame(() => {
    sizeShell(shell);
    scrollLogToEnd(shell);
    keepComposerInView(shell);
  });
}

function animateOnce(element, className) {
  if (!element || reducedMotion()) return;
  element.classList.add(className);
  element.addEventListener("animationend", () => element.classList.remove(className), { once: true });
}

// The gallery slides away, then the stream removes it.
function leave(element) {
  if (!element || reducedMotion()) return Promise.resolve();
  element.classList.add("agent-shell-leaving");
  return new Promise((resolve) => {
    let done = false;
    const finish = () => { if (!done) { done = true; resolve(); } };
    element.addEventListener("transitionend", finish, { once: true });
    setTimeout(finish, 320);
  });
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:before-stream-render", (event) => {
    const stream = event.target;
    const action = stream.getAttribute("action");
    const target = stream.getAttribute("target");
    const original = event.detail.render;
    const statusWasHeading = target === STATUS_ID && document.getElementById(STATUS_ID)?.dataset.card === "false";
    const firstThread = target === CHAT_ID && action === "replace" && !document.getElementById(CHAT_ID)?.hasAttribute("data-build-chat");

    event.detail.render = async (element) => {
      if (action === "remove" && target === GALLERY_ID) await leave(document.getElementById(GALLERY_ID));
      await original(element);
      if (firstThread) animateOnce(document.getElementById(CHAT_ID), "agent-shell-enter-thread");
      if (statusWasHeading && document.getElementById(STATUS_ID)?.dataset.card === "true") {
        animateOnce(document.querySelector("[data-test='build-status-card']"), "agent-shell-enter-card");
      }
      settle();
    };
  });

  document.addEventListener("turbo:load", settle);
  window.addEventListener("resize", () => {
    const shell = document.querySelector(SHELL);
    if (shell) sizeShell(shell);
  }, { passive: true });
}
