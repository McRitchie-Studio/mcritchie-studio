// The /build agent shell's two behaviours (app/views/build/new.html.erb;
// .agents/epics/build-with-ray-v2.md, section 6):
//
//   - the FIRST message never leaves the page. The composer posts through Turbo;
//     BuildController#create answers with Turbo Streams that swap the empty
//     thread for the new draft's chat (Ray's thread, polled by build_chat.js) and
//     end with a `replace_url` stream, which moves the address bar to
//     /build/<token> through Turbo's own history (so Back and the snapshot cache
//     agree), with no reload. Then the new chat box takes the focus.
//   - the first chat box's own manners (build/_first_form, no inline Alpine):
//     Enter sends and Shift+Enter is a new line; the box grows with the text up
//     to 320px; send is off until there is text, and one send at a time; at
//     send the bot shield's proof is written in (BrowserProof: the signed render
//     time, reversed, which only a script running the page can do).
//     At send a screen reader hears "Sending…" ([data-composer-status], a
//     polite status line), cleared when the post ends.
//   - the empty chat box's typing placeholder is app/javascript/typing_placeholder.js,
//     whose timer runs only while /build's first box is on the page.
//
// Imported by application.js on every page, once per load; listeners delegated
// on document, so a Turbo visit needs no re-binding.
import { Turbo } from "@hotwired/turbo-rails";
import "typing_placeholder";

Turbo.StreamActions.replace_url = function replaceUrl() {
  const url = this.getAttribute("url");
  if (!url) return;
  const target = new URL(url, window.location.href);
  if (target.origin !== window.location.origin) return;
  const history = Turbo.session?.history;
  if (history?.replace) {
    history.replace(target, history.restorationIdentifier);
    // Turbo files the page's snapshot under the view's last rendered location
    // when the visitor leaves (PageView#cacheSnapshot). history.replace does not
    // move it, so without this the draft's thread would be cached as "/build"
    // and flash as the preview of the next visit to /build.
    if (Turbo.session.view) Turbo.session.view.lastRenderedLocation = target;
  } else {
    window.history.replaceState(window.history.state, "", target.href);
  }
  requestAnimationFrame(() => document.querySelector("[data-cto-chat-form] textarea")?.focus());
};

const FIRST_FORM = "form[data-build-first-form]";

function syncSend(form) {
  const input = form.querySelector("[data-build-first-input]");
  const send = form.querySelector("[data-build-first-send]");
  if (input && send) send.disabled = form.dataset.sending === "true" || input.value.trim() === "";
}

document.addEventListener("input", (event) => {
  const input = event.target.closest?.("[data-build-first-input]");
  if (!input) return;
  input.style.height = "auto";
  input.style.height = `${Math.min(input.scrollHeight, 320)}px`;
  syncSend(input.form);
});

document.addEventListener("keydown", (event) => {
  const input = event.target.closest?.("[data-build-first-input]");
  if (!input || event.key !== "Enter" || event.shiftKey || event.isComposing) return;
  event.preventDefault();
  input.form.requestSubmit();
});

// Capture phase: before Turbo reads the form, so a refused send never posts.
document.addEventListener("submit", (event) => {
  const form = event.target.closest?.(FIRST_FORM);
  if (!form) return;
  const input = form.querySelector("[data-build-first-input]");
  if (!input || input.value.trim() === "" || form.dataset.sending === "true") {
    event.preventDefault();
    event.stopImmediatePropagation();
    return;
  }
  const proof = form.querySelector("[data-build-proof]");
  if (proof && !proof.value) proof.value = (proof.dataset.proof || "").split("").reverse().join("");
  form.dataset.sending = "true";
  syncSend(form);
  announce(form, "Sending…");
}, true);

document.addEventListener("turbo:submit-end", (event) => {
  const form = event.target.closest?.(FIRST_FORM);
  if (!form) return;
  delete form.dataset.sending;
  syncSend(form);
  announce(form, "");
});

// The screen-reader cue the round send button cannot carry in its icon.
function announce(form, text) {
  const status = form.querySelector("[data-composer-status]");
  if (status) status.textContent = text;
}
