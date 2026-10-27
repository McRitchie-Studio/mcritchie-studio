// The Gmail admin-trust modal's behaviour (app/views/modals/_gmail_admin.html.erb,
// task google-verification-readiness). The template reads its props straight from
// $store.modals and calls these two helpers from Alpine attributes, so it carries no
// x-data of its own and no inline <script> (CSP).
//
//   :href="window.GmailAdmin.mailto(clientId)"   the prefilled "Email my admin" link
//   @click="window.GmailAdmin.copy($el, clientId)" copies the OAuth client id, then
//                                                 says Copied or Copy failed for a moment
const SUBJECT = "Please trust McRitchie Studio in our Google Workspace";

function mailto(clientId) {
  const id = clientId || "";
  const body = [
    "Hi,",
    "",
    "I would like to connect my Gmail to McRitchie Studio (read only). Google asks our Workspace admin to trust the app first. It takes about two minutes:",
    "",
    "1. Sign in to https://admin.google.com",
    "2. Go to Security > Access and data control > API controls > Manage Third-Party App Access > Configure new app",
    id ? `3. Search for this client ID and select McRitchie Studio: ${id}` : "3. Search for McRitchie Studio and select it",
    "4. Choose Trusted.",
    "",
    "Thank you!",
  ].join("\r\n"); // RFC 6068: a mailto body breaks lines with CRLF; some mail clients join bare LFs into one line
  return `mailto:?subject=${encodeURIComponent(SUBJECT)}&body=${encodeURIComponent(body)}`;
}

async function copy(button, clientId) {
  const label = button.querySelector("[data-copy-label]") || button;
  try {
    await navigator.clipboard.writeText(clientId || "");
    label.textContent = "Copied";
  } catch (_error) {
    label.textContent = "Copy failed";
  }
  clearTimeout(button._gmailAdminReset);
  button._gmailAdminReset = setTimeout(() => { label.textContent = "Copy"; }, 2000);
}

window.GmailAdmin = { mailto, copy };
