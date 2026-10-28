// The shared agent web chat (app/views/agent_chats; first page: the CTO chat at
// /applications/:slug/chat). The page's Turbo stream appends turns, replaces a
// turn when its answer lands, and pulses "typing…" into the typing slot. This
// module only keeps the view honest around those streams:
//
//   - the log opens at its newest turn, and after every stream render keeps a
//     reader who was at the end there (chat_follow.js; one scrolled up stays);
//   - a typing pulse fades data-fade-seconds after it arrived, so a run that
//     dies stops "typing" within seconds (the dispatcher pulses every 7s), and
//     a pulse older than an answer already shown is dropped at once;
//   - a pulse carries its phase (data-phase: thinking, then typing). Each
//     pulse redraws the indicator, so the phase the old one showed is carried
//     onto the new one for a frame and then let go, and the CSS
//     (agent_typing.css) crossfades the swap; every redraw also gets the page
//     clock's place in the motion's beat (--agent-typing-sync), so the ring,
//     shimmer and dots run on without a restart;
//   - Enter sends, Shift+Enter is a new line, and the composer keeps focus;
//   - while a send posts, its status line reads "Sending…" for a screen reader;
//   - a send spends the composer the moment Turbo has read it (startSend): a
//     fresh client id, the box emptied, its files' chips taken off. The sent
//     turn is broadcast as well as answered, and the broadcast can land first,
//     so the owner may write again while the OLD composer is still on the page.
//     That message once rode the last one's client id and AgentMessages::WebIngest
//     kept it as a double submit: it vanished (task shell-growth-spec-stops-flaking).
//     When the answer's fresh composer lands, what the owner had going in the
//     old one is carried into it: a draft typed meanwhile (carriedDraft, beside
//     a refused send's echo, never under it), files attached meanwhile, the
//     caret. A send that never reached the server puts its text and its own
//     files back (putBack); a refusal the server redraws shows only what the
//     server kept; a file another send carried never comes back. An ask
//     (build_status.js) sets the visitor's draft aside and the send puts it
//     straight back. The composer stays aria-busy until the LAST send in flight
//     settles (trackSend). One empty send while a send posts is a double submit,
//     and is dropped; one that carries files is a message (emptyRepeat). Task
//     composer-edge-cases.
//
// Its hooks keep their cto-chat names (data-cto-chat-*, #cto-chat-typing, the
// AgentMessages::WebChat targets) for every agent, so the CTO page is unchanged.
// Imported by application.js on every page, once per load; every listener is
// delegated on document and does nothing where there is no chat, so a Turbo
// visit to or back to the chat needs no re-binding. "cto_chat" is pinned to
// this file too (config/importmap.rb), so the old import still loads it.
import { follow, stickIfFollowing } from "chat_follow";

const LOG = "[data-cto-chat-scroll]";
const TYPING = "cto-chat-typing";
const FORM = "[data-cto-chat-form]";
const INDICATOR = "[data-test='cto-chat-typing'][data-phase]";
// agent_typing.css's --agent-typing-beat, in ms: every loop divides it.
export const BEAT_MS = 2400;
let fadeTimer = null;

// Where an indicator lives, the same before and after a redraw: its typing slot
// on the CTO chat (#cto-chat-typing), its turn on /build (#build-turn-N).
export function indicatorKey(indicator) {
  return indicator.parentElement?.closest?.("[id]")?.id || "";
}

// key -> phase, for every indicator in `root` (read before a stream renders).
export function phasesIn(root) {
  const phases = new Map();
  root?.querySelectorAll?.(INDICATOR).forEach((indicator) => {
    phases.set(indicatorKey(indicator), indicator.dataset.phase);
  });
  return phases;
}

// A redrawn indicator whose phase moved on: show the old phase for one frame,
// then the new, so the CSS transition runs. Returns true when it swapped.
export function carryPhase(indicator, previous, frame = (fn) => requestAnimationFrame(fn)) {
  const next = indicator.dataset.phase;
  if (!previous || previous === next) return false;
  indicator.dataset.phase = previous;
  void indicator.offsetWidth; // commit the old look before the swap
  frame(() => {
    indicator.dataset.phase = next;
  });
  return true;
}

// The negative delay that puts a fresh animation at the page clock's place in
// the beat, as a CSS time.
export function syncDelay(now = Date.now()) {
  return `-${now % BEAT_MS}ms`;
}

// A fresh client id for the composer's next send (AgentMessages::WebIngest::CLIENT_ID
// takes a UUID). Empty where the browser has none: the server then mints one.
export function freshClientId(random = () => globalThis.crypto?.randomUUID?.()) {
  return random() || "";
}

const CHIP = "[data-chat-attachment-chip]";
const CHIPS = "[data-chat-attachments-chips]";
const TOKEN = "input[name$='[attachments][]']";

function tokenOf(chip) {
  return chip.querySelector?.(TOKEN)?.value || "";
}

// The text box is required only while no file rides the message (chat_attachments.js
// keeps the same rule as files come and go).
function syncRequired(form) {
  const field = form.querySelector("textarea");
  if (field) field.required = form.querySelectorAll(CHIP).length === 0;
}

// The send Turbo has just read out of `form` is on its way: give the form a fresh
// client id, empty its box, and take its sent files' chips off the form (Turbo has
// already read their tokens), so a second send from this same form is a message of
// its own, never the first again, and no sent file can ride a later one. A draft
// an ask set aside (build_status.js#askAgent: data-ask-draft) goes back in the box
// at once: the ask is what was sent, and the visitor's own words are theirs again.
// Returns what was sent, { text, files }, for restoreSend.
export function startSend(form, random) {
  const field = form.querySelector("textarea");
  const text = field?.value || "";
  const id = form.querySelector("input[name$='[client_id]']");
  if (id) id.value = freshClientId(random);
  if (field) field.value = "";
  const files = Array.from(form.querySelectorAll(CHIP)).filter((chip) => tokenOf(chip) !== "");
  files.forEach((chip) => chip.remove());
  const draft = form.dataset?.askDraft;
  if (draft !== undefined) {
    delete form.dataset.askDraft;
    if (field) field.value = draft;
  }
  syncRequired(form);
  return { text, files };
}

// Puts `chips` into `form`'s file list, skipping a file it already holds (a
// refused send's files come back drawn by the server). Returns how many went in.
export function addChips(form, chips) {
  const holder = form?.querySelector(CHIPS);
  if (!holder) return 0;
  const held = new Set(Array.from(form.querySelectorAll(TOKEN)).map((token) => token.value));
  let added = 0;
  chips.forEach((chip) => {
    const token = tokenOf(chip);
    if (token !== "" && held.has(token)) return;
    holder.append(chip);
    if (token !== "") held.add(token);
    added += 1;
  });
  syncRequired(form);
  return added;
}

// A send that failed (sendFailed): its files, and its text and client id unless
// something new was typed meanwhile, go back in. Only that send's own files: a
// file another send carried stays sent. The id matters: the server may have
// stored the send before the answer was lost, and a retry on the same id is then
// kept once (WebIngest), not stored twice. True when the text went back.
export function restoreSend(form, sent, clientId) {
  addChips(form, sent?.files || []);
  const field = form.querySelector("textarea");
  if (!field || field.value.trim() !== "" || !sent?.text) return false;
  field.value = sent.text;
  const id = form.querySelector("input[name$='[client_id]']");
  if (id && clientId) id.value = clientId;
  return true;
}

// Whether a send's submit-end means it failed: a network error, or an answer that
// was not a success (an empty 429 draws nothing, so the box would stay empty). A send
// aborted by the next one carries neither, and is not put back.
export function sendFailed(detail) {
  return Boolean(detail?.error) || Boolean(detail?.fetchResponse && !detail.success);
}

// Whether a failed send is put back by the client (restoreSend). Not when the
// server's answer is a Turbo Stream: that answer redraws the composer with what
// the server kept (the refused text, and only the still-valid files,
// AgentMessages::Attachments.held), and the server's set wins. Putting the
// send's own chips back would bring a dead file (expired, already used) back
// looking ready. Only a failure that draws nothing (a network error, an empty
// 429) is put back by the client.
export function putBack(detail) {
  if (!sendFailed(detail)) return false;
  return !/turbo-stream/.test(detail?.fetchResponse?.contentType || "");
}

// The composer a submit event belongs to. Turbo sends turbo:submit-end to
// document.documentElement once the form has left the page (its dispatch falls
// back when the target is detached), so the form is read from the submission.
export function formOfEvent(event, selector = FORM) {
  const own = event?.detail?.formSubmission?.formElement;
  if (own?.matches?.(selector)) return own;
  const target = event?.target;
  return target?.closest?.(selector) || null;
}

// What a composer redrawn by the server holds, losing nothing the owner wrote:
// what the server drew there (a refused send's text, echoed back with its reason)
// and what was being typed while the send posted (a draft, or an ask's set-aside
// draft). Both, the echo first, unless one already holds the other.
export function carriedDraft(drawn, typed) {
  const shown = drawn || "";
  const kept = typed || "";
  if (kept.trim() === "" || kept.trim() === shown.trim()) return shown;
  if (shown.trim() === "" || kept.trim().startsWith(shown.trim())) return kept;
  return `${shown}\n${kept}`;
}

// Whether an empty send is the same send twice (a second Enter, a second tap while
// one posts), to be dropped: only while a send posts, and only with no file on it.
// A files-only message is a message.
export function emptyRepeat(form) {
  if (form.getAttribute("aria-busy") !== "true") return false;
  if ((form.querySelector("textarea")?.value || "").trim() !== "") return false;
  return form.querySelectorAll(CHIP).length === 0;
}

// The sends in flight, per composer id. Turbo marks a form busy at each send's
// start and clears it at each one's end, so when sends overlap (the second aborts
// the first, whose end lands after the second's start) the first one's end left
// the composer "not busy" while the second still posted. Counted here instead:
// busy until the LAST send in flight settles. Returns the count left.
export function trackSend(inflight, formId, submission, started) {
  const sends = inflight.get(formId) || new Set();
  if (started) sends.add(submission); else sends.delete(submission);
  if (sends.size === 0) inflight.delete(formId); else inflight.set(formId, sends);
  return sends.size;
}

export function markBusy(form, count) {
  if (!form) return;
  if (count > 0) form.setAttribute("aria-busy", "true");
  else form.removeAttribute("aria-busy");
}

// Puts the caret at the end of the composer's box.
export function focusComposer(form) {
  const field = form?.querySelector("textarea");
  if (!field) return false;
  field.focus();
  const end = field.value.length;
  field.setSelectionRange?.(end, end);
  return true;
}

// A stream that redraws a chat composer: the composer it replaces, or null.
function composerTarget(stream) {
  if (!stream?.getAttribute) return null;
  if (!["replace", "update"].includes(stream.getAttribute("action"))) return null;
  const target = document.getElementById(stream.getAttribute("target") || "");
  return target?.matches?.(FORM) ? target : null;
}

function settleIndicators(before, now = Date.now()) {
  document.querySelectorAll(INDICATOR).forEach((indicator) => {
    indicator.style.setProperty("--agent-typing-sync", syncDelay(now));
    carryPhase(indicator, before?.get(indicatorKey(indicator)));
  });
}

function newestReply() {
  let newest = 0;
  document.querySelectorAll(`${LOG} [data-replied-at]`).forEach((turn) => {
    newest = Math.max(newest, Number(turn.dataset.repliedAt) || 0);
  });
  return newest;
}

function settleTyping() {
  const slot = document.getElementById(TYPING);
  if (!slot) return;
  const pulse = slot.querySelector("[data-typing-at]");
  clearTimeout(fadeTimer);
  if (!pulse) return;
  if (Number(pulse.dataset.typingAt) <= newestReply()) {
    slot.replaceChildren();
    return;
  }
  const seconds = Number(slot.dataset.fadeSeconds) || 12;
  fadeTimer = setTimeout(() => slot.replaceChildren(), seconds * 1000);
}

function afterRender() {
  requestAnimationFrame(() => {
    settleTyping();
    stickIfFollowing(document.querySelector(LOG));
  });
}

if (typeof document !== "undefined") {
  // The sends in flight, per composer id (trackSend).
  const inflight = new Map();
  const sending = new WeakMap();

  // A composer redraw (the send's answer) builds a fresh form, so what the owner
  // had going in the old one is carried across: the draft (carriedDraft), files
  // attached while the send posted, uploading or ready (their chips move, so an
  // upload still running lands in the new form; a send held for them stays
  // held), the busy mark of a send still in flight, and the caret, when it was in
  // the box the redraw took away.
  document.addEventListener("turbo:before-stream-render", (event) => {
    const original = event.detail.render;
    event.detail.render = async (stream) => {
      const before = phasesIn(document);
      const composer = composerTarget(stream);
      const typed = composer?.querySelector("textarea")?.value || "";
      const formId = composer?.id;
      const files = composer ? Array.from(composer.querySelectorAll(CHIP)) : [];
      const heldForFiles = composer?.dataset.chatAttachmentsHeld;
      const focused = Boolean(composer?.contains(document.activeElement));
      await original(stream);
      const fresh = formId ? document.getElementById(formId) : null;
      if (fresh) {
        const field = fresh.querySelector("textarea");
        if (field && typed.trim() !== "" && field.value !== carriedDraft(field.value, typed)) {
          field.value = carriedDraft(field.value, typed);
          field.dispatchEvent(new Event("input", { bubbles: true }));
        }
        addChips(fresh, files);
        if (heldForFiles) fresh.dataset.chatAttachmentsHeld = heldForFiles;
        markBusy(fresh, inflight.get(formId)?.size || 0);
        if (focused) focusComposer(fresh);
      }
      settleIndicators(before);
      afterRender();
    };
  });

  // Capture phase, before Turbo reads the form: an empty send while one posts is
  // the same send twice (a second Enter, a second tap), so it is dropped. One
  // that carries files is a message, and goes (emptyRepeat).
  document.addEventListener("submit", (event) => {
    const form = event.target.closest?.(FORM);
    if (!form || !emptyRepeat(form)) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);

  document.addEventListener("keydown", (event) => {
    const input = event.target;
    if (!(input instanceof HTMLTextAreaElement) || !input.closest(FORM)) return;
    if (event.key !== "Enter" || event.shiftKey || event.isComposing) return;
    event.preventDefault();
    if (input.value.trim() !== "") input.form.requestSubmit();
  });

  // The send button is an icon, so a screen reader hears "Sending…" from the
  // composer's polite status line ([data-composer-status]) while the post runs.
  function announce(form, text) {
    const status = form?.querySelector("[data-composer-status]");
    if (status) status.textContent = text;
  }

  document.addEventListener("turbo:submit-start", (event) => {
    const form = event.target.closest?.(FORM);
    const submission = event.detail?.formSubmission;
    if (!form) return;
    announce(form, "Sending…");
    if (!submission) return;
    markBusy(form, trackSend(inflight, form.id, submission, true));
    // Keyed by the submission: a send aborted by the next one ends after it starts.
    const clientId = form.querySelector("input[name$='[client_id]']")?.value;
    sending.set(submission, { ...startSend(form), clientId });
  });

  document.addEventListener("turbo:submit-end", (event) => {
    const ended = formOfEvent(event);
    if (!ended) return;
    // A send from a composer since redrawn ends on the detached old form (Turbo
    // then dispatches on the document element; formOfEvent reads the form from
    // the submission): what it puts back, and its busy count, go to the
    // composer on the page.
    const form = (ended.id && document.getElementById(ended.id)) || ended;
    const submission = event.detail?.formSubmission;
    const sent = submission && sending.get(submission);
    if (sent && putBack(event.detail)) restoreSend(form, sent, sent.clientId);
    if (submission) sending.delete(submission);
    const left = submission ? trackSend(inflight, ended.id, submission, false) : 0;
    markBusy(form, left);
    if (left === 0) announce(form, "");
    requestAnimationFrame(() => document.querySelector(`${FORM} textarea`)?.focus());
  });

  function init() {
    const log = document.querySelector(LOG);
    if (!log) return;
    follow(log);
    settleIndicators(null);
    settleTyping();
  }

  document.addEventListener("turbo:load", init);
  init();
}
