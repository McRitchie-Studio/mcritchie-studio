// The Pending agents table on /agents (app/views/agent_setups/; SOP
// docs/agents/agents/steffon/sops/agent-onboarding.md). Delegated listeners, so it
// is inert on every other page and survives Turbo visits:
//
//   [data-agent-setup-toggle]   a row's disclosure button: shows its steps row
//                               (aria-controls) and closes any other open one, so
//                               at most one checklist is open at a time
//   [data-copy-clip]            copies the button's text to the clipboard
//                               (window.copyText, components/_copy_text_script)
//                               and says "Copied" for a moment
//   [data-agent-avatar-png]     the avatar download: the hub keeps souls'
//                               avatars as WebP and the Developer Portal's App
//                               Icon takes PNG, JPG or GIF, so the click draws the
//                               hub's own image into a 1024px square (cover crop)
//                               and saves it as a PNG. Same-origin, so the canvas
//                               is never tainted. Anything that fails leaves the
//                               link's own href (the WebP) to the browser.

function setOpen(button, open) {
  const row = document.getElementById(button.getAttribute("aria-controls"));
  if (!row) return;
  row.hidden = !open;
  button.setAttribute("aria-expanded", open ? "true" : "false");
  const label = button.querySelector("[data-toggle-label]");
  if (label) label.textContent = open ? "Hide" : "Steps";
}

function toggle(button) {
  const opening = button.getAttribute("aria-expanded") !== "true";
  if (opening) {
    document.querySelectorAll("[data-agent-setup-toggle][aria-expanded='true']").forEach((other) => {
      if (other !== button) setOpen(other, false);
    });
  }
  setOpen(button, opening);
}

function copy(button) {
  const done = () => {
    const was = button.dataset.copyLabel || button.textContent;
    button.dataset.copyLabel = was;
    button.textContent = "Copied";
    setTimeout(() => { button.textContent = button.dataset.copyLabel; }, 1400);
  };
  if (window.copyText) Promise.resolve(window.copyText(button.dataset.copyClip)).then(done);
}

function avatarPng(link) {
  const url = link.getAttribute("href");
  const name = link.dataset.filename || "avatar.png";
  const img = new Image();
  img.onload = () => {
    try {
      const size = 1024;
      const canvas = document.createElement("canvas");
      canvas.width = size;
      canvas.height = size;
      const scale = Math.max(size / img.naturalWidth, size / img.naturalHeight);
      const w = img.naturalWidth * scale;
      const h = img.naturalHeight * scale;
      canvas.getContext("2d").drawImage(img, (size - w) / 2, (size - h) / 2, w, h);
      canvas.toBlob((blob) => {
        if (!blob) { window.location.href = url; return; }
        const a = document.createElement("a");
        a.href = URL.createObjectURL(blob);
        a.download = name;
        document.body.appendChild(a);
        a.click();
        a.remove();
        setTimeout(() => URL.revokeObjectURL(a.href), 1000);
      }, "image/png");
    } catch (_error) {
      window.location.href = url;
    }
  };
  img.onerror = () => { window.location.href = url; };
  img.src = url;
}

document.addEventListener("click", (event) => {
  const toggleButton = event.target.closest("[data-agent-setup-toggle]");
  if (toggleButton) { toggle(toggleButton); return; }

  const copyButton = event.target.closest("[data-copy-clip]");
  if (copyButton && copyButton.closest("[data-test='pending-agents']")) { copy(copyButton); return; }

  const avatar = event.target.closest("[data-agent-avatar-png]");
  if (avatar) {
    event.preventDefault();
    avatarPng(avatar);
  }
});
