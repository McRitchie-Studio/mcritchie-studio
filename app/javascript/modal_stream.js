// A Turbo Stream that opens one of the layout's engine modals (task
// build-sign-in-modal): <turbo-stream action="open_modal" modal="auth"
// props='{"returnTo":"/build/<token>/launch","title":"…","subtitle":"…"}'>.
// BuildController#sign_in_to_launch answers a signed-out Build My App with it,
// so the press opens the sign-in modal (app/views/modals/_auth.html.erb) over
// the chat instead of adding a step to it; every press answers again, so a
// dismissed modal opens again on the next one.
//
// Props are data, read as JSON; a malformed one opens the modal with its
// default copy. With no modal store on the page (Alpine not started), nothing
// happens: the press is already remembered on the server.
//
// Imported by application.js on every page; it only registers the action.
import { Turbo } from "@hotwired/turbo-rails";

export function readProps(raw) {
  if (!raw) return {};
  try {
    const props = JSON.parse(raw);
    return props && typeof props === "object" && !Array.isArray(props) ? props : {};
  } catch (_e) {
    return {};
  }
}

Turbo.StreamActions.open_modal = function openModal() {
  const id = this.getAttribute("modal");
  const store = window.Alpine?.store?.("modals");
  if (!id || typeof store?.open !== "function") return;
  store.open(id, readProps(this.getAttribute("props")));
};
