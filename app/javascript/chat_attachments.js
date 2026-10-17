// The chat composer's files (app/views/agent_chats/_attachments.html.erb; the rules
// are the server's, AgentMessages::Attachments, and these checks only spare a
// round trip). A file arrives by the Attach button, a paste into the form, or a
// drop anywhere on the page, and uploads AT ONCE, one request per file, to the
// partial's data-upload-url, with a chip showing its name and a progress bar.
// Each upload answers a token; the chip then carries it as a hidden form field
// (data-field-name), and removing the chip removes the field.
//
// Send waits for the uploads: a submit while any is in flight is held and
// re-sent the moment the last one settles, unless one FAILED: then nothing is
// sent, the failed chip stays (red, with the server's reason) and the composer
// says to remove it or attach it again. A submit with a failed chip on it is
// stopped the same way. A message may be files with no text, so the text box is
// required only while a file is attached or uploading.
//
// Imported by application.js on every page, once per load; every listener is
// delegated on document and does nothing where there is no composer.
const ROOT = "[data-chat-attachments]";
const IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/gif", "image/heic", "image/heif"];
const EXTENSIONS = { png: "image/png", jpg: "image/jpeg", jpeg: "image/jpeg", webp: "image/webp", gif: "image/gif",
  heic: "image/heic", heif: "image/heif", pdf: "application/pdf" };
let dragDepth = 0;

function rootIn(form) { return form?.querySelector(ROOT) || null; }
function pageRoot() { return document.querySelector(ROOT); }

function typeOf(file) {
  if (file.type && (IMAGE_TYPES.includes(file.type) || file.type === "application/pdf")) return file.type;
  const ext = (file.name || "").split(".").pop().toLowerCase();
  return EXTENSIONS[ext] || file.type || "";
}

function megabytes(bytes) { return Math.round(bytes / (1024 * 1024)); }

function showError(root, text) {
  const slot = root.querySelector("[data-chat-attachments-error]");
  if (!slot) return;
  slot.textContent = text || "";
  slot.classList.toggle("hidden", !text);
}

function chips(root) { return Array.from(root.querySelectorAll("[data-chat-attachment-chip]")); }
function uploading(root) { return chips(root).some((chip) => chip.dataset.state === "uploading"); }

// The text box is required only while no file rides the message.
function syncRequired(root) {
  const form = root.closest("form");
  const input = form?.querySelector("textarea");
  if (!input) return;
  const ready = chips(root).length > 0;
  input.required = !ready;
  const send = form.querySelector("[type='submit']");
  if (send) send.toggleAttribute("aria-busy", uploading(root));
}

function precheck(root, file) {
  const type = typeOf(file);
  const name = file.name || "file";
  if (type === "application/pdf") {
    if (file.size > Number(root.dataset.maxPdfBytes)) return `${name} is over ${megabytes(Number(root.dataset.maxPdfBytes))} MB, the limit for a PDF.`;
    return null;
  }
  if (!IMAGE_TYPES.includes(type)) return `${name} is not an image or a PDF. Attach PNG, JPG, WebP, GIF, HEIC or PDF.`;
  if (file.size > Number(root.dataset.maxImageBytes)) return `${name} is over ${megabytes(Number(root.dataset.maxImageBytes))} MB, the limit for an image.`;
  return null;
}

function chipFor(file) {
  const chip = document.createElement("li");
  chip.dataset.chatAttachmentChip = "";
  chip.dataset.test = "cto-chat-chip";
  chip.dataset.state = "uploading";
  chip.className = "relative flex items-center gap-2 max-w-[16rem] rounded-xl border border-subtle bg-surface pl-2 pr-1 py-1 text-xs text-heading";

  const type = typeOf(file);
  if (["image/png", "image/jpeg", "image/webp", "image/gif"].includes(type) && window.URL?.createObjectURL) {
    const img = document.createElement("img");
    img.src = URL.createObjectURL(file);
    img.alt = "";
    img.className = "h-8 w-8 shrink-0 rounded object-cover";
    img.addEventListener("load", () => URL.revokeObjectURL(img.src), { once: true });
    chip.append(img);
  } else {
    const badge = document.createElement("span");
    badge.className = "shrink-0 font-semibold text-muted";
    badge.textContent = type === "application/pdf" ? "PDF" : "IMG";
    chip.append(badge);
  }

  const body = document.createElement("span");
  body.className = "min-w-0 flex flex-col gap-1";
  const name = document.createElement("span");
  name.className = "truncate";
  name.dataset.test = "cto-chat-chip-name";
  name.textContent = file.name || "file";
  const bar = document.createElement("progress");
  bar.max = 100;
  bar.value = 0;
  bar.className = "h-1 w-24";
  bar.dataset.test = "cto-chat-chip-progress";
  bar.setAttribute("aria-label", `Uploading ${file.name || "file"}`);
  const note = document.createElement("span");
  note.className = "hidden text-danger-ink whitespace-normal";
  note.dataset.test = "cto-chat-chip-error";
  body.append(name, bar, note);
  chip.append(body);

  const remove = document.createElement("button");
  remove.type = "button";
  remove.className = "shrink-0 inline-flex items-center justify-center min-w-6 min-h-6 rounded text-base leading-none text-muted hover:text-heading";
  remove.dataset.chatAttachmentRemove = "";
  remove.dataset.test = "cto-chat-chip-remove";
  remove.setAttribute("aria-label", `Remove ${file.name || "file"}`);
  remove.textContent = "×";
  chip.append(remove);
  return chip;
}

function fail(root, chip, text) {
  chip.dataset.state = "failed";
  // Swap, not add: with both on the chip the stylesheet's order would decide.
  chip.classList.remove("border-subtle");
  chip.classList.add("border-danger");
  chip.querySelector("progress")?.remove();
  const note = chip.querySelector("[data-test='cto-chat-chip-error']");
  if (note) {
    note.textContent = text;
    note.classList.remove("hidden");
  }
  settle(root);
}

function done(root, chip, token) {
  chip.dataset.state = "done";
  chip.querySelector("progress")?.remove();
  const field = document.createElement("input");
  field.type = "hidden";
  field.name = root.dataset.fieldName;
  field.value = token;
  chip.append(field);
  settle(root);
}

const FAILED_HOLD = "A file did not upload. Remove it or attach it again, then send.";

function failed(root) { return chips(root).some((chip) => chip.dataset.state === "failed"); }

// After any upload settles: re-send a held submit once nothing is in flight,
// unless an upload failed; then the send stays unsent and says why.
function settle(root) {
  syncRequired(root);
  if (uploading(root)) return;
  const form = root.closest("form");
  if (form?.dataset.chatAttachmentsHeld !== "1") return;
  delete form.dataset.chatAttachmentsHeld;
  if (failed(root)) {
    showError(root, FAILED_HOLD);
    return;
  }
  form.requestSubmit();
}

function upload(root, file, chip) {
  const data = new FormData();
  data.append("file", file, file.name || "file");
  const xhr = new XMLHttpRequest();
  xhr.open("POST", root.dataset.uploadUrl);
  xhr.setRequestHeader("Accept", "application/json");
  const csrf = document.querySelector("meta[name='csrf-token']")?.content;
  if (csrf) xhr.setRequestHeader("X-CSRF-Token", csrf);
  xhr.upload.addEventListener("progress", (event) => {
    if (!event.lengthComputable) return;
    const bar = chip.querySelector("progress");
    if (bar) bar.value = Math.round((event.loaded / event.total) * 100);
  });
  xhr.addEventListener("load", () => {
    let body = {};
    try { body = JSON.parse(xhr.responseText || "{}"); } catch (_e) { body = {}; }
    if (xhr.status === 201 && body.token) done(root, chip, body.token);
    else fail(root, chip, body.error || "That file did not upload. Try again.");
  });
  xhr.addEventListener("error", () => fail(root, chip, "That file did not upload. Check the connection and try again."));
  xhr.send(data);
}

function addFiles(root, files) {
  const list = Array.from(files || []);
  if (list.length === 0) return;
  const max = Number(root.dataset.maxFiles) || 10;
  const room = max - chips(root).filter((chip) => chip.dataset.state !== "failed").length;
  showError(root, list.length > room ? `Attach at most ${max} files to one message.` : "");
  const holder = root.querySelector("[data-chat-attachments-chips]");
  list.slice(0, Math.max(room, 0)).forEach((file) => {
    const chip = chipFor(file);
    holder.append(chip);
    const problem = precheck(root, file);
    if (problem) fail(root, chip, problem);
    else upload(root, file, chip);
  });
  syncRequired(root);
}

function hasFiles(event) {
  return Array.from(event.dataTransfer?.types || []).includes("Files");
}

function dropZone(on) {
  const zone = pageRoot()?.querySelector("[data-chat-attachments-drop]");
  if (!zone) return;
  zone.classList.toggle("hidden", !on);
  zone.classList.toggle("flex", on);
}

document.addEventListener("change", (event) => {
  const input = event.target;
  if (!(input instanceof HTMLInputElement) || !input.matches("[data-chat-attachments-input]")) return;
  const root = input.closest(ROOT);
  if (root) addFiles(root, input.files);
  input.value = "";
});

document.addEventListener("click", (event) => {
  const remove = event.target.closest?.("[data-chat-attachment-remove]");
  if (!remove) return;
  const root = remove.closest(ROOT);
  remove.closest("[data-chat-attachment-chip]")?.remove();
  if (root) {
    showError(root, "");
    settle(root);
  }
});

document.addEventListener("paste", (event) => {
  const root = rootIn(event.target.closest?.("form"));
  const files = event.clipboardData?.files;
  if (!root || !files || files.length === 0) return;
  event.preventDefault();
  addFiles(root, files);
});

document.addEventListener("dragenter", (event) => {
  if (!pageRoot() || !hasFiles(event)) return;
  dragDepth += 1;
  dropZone(true);
});

document.addEventListener("dragover", (event) => {
  if (!pageRoot() || !hasFiles(event)) return;
  event.preventDefault();
  event.dataTransfer.dropEffect = "copy";
});

document.addEventListener("dragleave", (event) => {
  if (!pageRoot() || !hasFiles(event)) return;
  dragDepth = Math.max(dragDepth - 1, 0);
  if (dragDepth === 0) dropZone(false);
});

document.addEventListener("drop", (event) => {
  const root = pageRoot();
  if (!root || !hasFiles(event)) return;
  event.preventDefault();
  dragDepth = 0;
  dropZone(false);
  addFiles(root, event.dataTransfer.files);
});

// Send waits for uploads: hold the submit, and settle() re-sends it. A failed
// chip stops the send outright.
document.addEventListener("submit", (event) => {
  const root = rootIn(event.target);
  if (!root || (!uploading(root) && !failed(root))) return;
  event.preventDefault();
  event.stopImmediatePropagation();
  if (uploading(root)) event.target.dataset.chatAttachmentsHeld = "1";
  else showError(root, FAILED_HOLD);
}, true);

// Enter sends a files-only message too (agent_chat.js sends only when there is text).
document.addEventListener("keydown", (event) => {
  const input = event.target;
  if (!(input instanceof HTMLTextAreaElement) || event.key !== "Enter" || event.shiftKey || event.isComposing) return;
  const root = rootIn(input.form);
  if (!root || input.value.trim() !== "") return;
  if (chips(root).some((chip) => ["done", "uploading", "failed"].includes(chip.dataset.state))) {
    event.preventDefault();
    input.form.requestSubmit();
  }
});

// A form drawn by the server (the page, or the form a refused send re-renders)
// may already hold ready chips: the text box is then not required.
function syncAll() { document.querySelectorAll(ROOT).forEach(syncRequired); }
document.addEventListener("turbo:load", syncAll);
document.addEventListener("turbo:before-stream-render", (event) => {
  const original = event.detail.render;
  event.detail.render = async (stream) => {
    await original(stream);
    syncAll();
  };
});
syncAll();
