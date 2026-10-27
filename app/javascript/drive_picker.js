// The Google Drive card's "Pick files" button (app/views/integrations/_drive_picks.html.erb,
// task drive-files-you-pick). No inline <script> (CSP): the button carries its URLs in
// data attributes and this module, imported by application.js, wires every one.
//
//   1. POST the token URL: the server mints a short-lived access token for the viewer's
//      OWN connection and returns it with the Picker's browser key and app id.
//   2. Load Google's loader (data-loader-url, apis.google.com) once, then its Picker.
//   3. Open the Picker: Drive files, several at once, folders shown to browse but not
//      selectable (Google grants no folder contents under drive.file).
//   4. On Picked, POST the chosen ids; the server reads each with the connection's
//      token before it records it, then the page reloads with the notice.
//
// A test can stand in for Google by defining window.gapi and window.google.picker before
// the click: an already-loaded Picker is used as is and the loader is never fetched.
const csrfToken = () => document.querySelector("meta[name='csrf-token']")?.content || "";

async function postJson(url, body) {
  const response = await fetch(url, {
    method: "POST",
    credentials: "same-origin",
    headers: { "Content-Type": "application/json", Accept: "application/json", "X-CSRF-Token": csrfToken() },
    body: JSON.stringify(body),
  });
  const json = await response.json().catch(() => ({}));
  // fetch resolves on a 4xx or 5xx: the status decides, not the promise.
  if (!response.ok) throw new Error(json.error || `The server answered ${response.status}.`);
  return json;
}

let loading = null;
function loadPicker(loaderUrl) {
  if (window.google?.picker) return Promise.resolve();
  loading ||= new Promise((resolve, reject) => {
    const ready = () => window.gapi.load("picker", { callback: resolve, onerror: () => reject(new Error("Google's Picker did not load.")) });
    if (window.gapi?.load) return ready();
    const script = document.createElement("script");
    script.src = loaderUrl;
    script.async = true;
    script.onload = ready;
    script.onerror = () => reject(new Error("Google's Picker could not be reached."));
    document.head.appendChild(script);
  }).catch((error) => { loading = null; throw error; });
  return loading;
}

function say(button, text) {
  const status = button.closest("[data-drive-picks]")?.querySelector("[data-drive-picker-status]");
  if (status) {
    status.textContent = text;
    status.hidden = !text;
  }
}

function openPicker(grant, onPicked) {
  const picker = window.google.picker;
  const view = new picker.DocsView(picker.ViewId.DOCS).setIncludeFolders(true).setSelectFolderEnabled(false);
  new picker.PickerBuilder()
    .addView(view)
    .enableFeature(picker.Feature.MULTISELECT_ENABLED)
    .enableFeature(picker.Feature.SUPPORT_DRIVES)
    .setOAuthToken(grant.access_token)
    .setDeveloperKey(grant.api_key)
    .setAppId(grant.app_id)
    .setCallback(onPicked)
    .build()
    .setVisible(true);
}

async function pick(button) {
  const { tokenUrl, picksUrl, loaderUrl, connectionId } = button.dataset;
  button.disabled = true;
  say(button, "");
  try {
    const grant = await postJson(tokenUrl, { connection_id: connectionId });
    await loadPicker(loaderUrl);
    openPicker(grant, async (data) => {
      const picker = window.google.picker;
      if (data[picker.Response.ACTION] !== picker.Action.PICKED) return;
      const ids = (data[picker.Response.DOCUMENTS] || []).map((doc) => doc[picker.Document.ID]);
      try {
        await postJson(picksUrl, { connection_id: connectionId, file_ids: ids });
        window.Turbo ? window.Turbo.visit(window.location.href, { action: "replace" }) : window.location.reload();
      } catch (error) {
        say(button, error.message);
      }
    });
  } catch (error) {
    say(button, error.message);
  } finally {
    button.disabled = false;
  }
}

document.addEventListener("click", (event) => {
  const button = event.target.closest("[data-drive-picker]");
  if (!button) return;
  event.preventDefault();
  pick(button);
});
