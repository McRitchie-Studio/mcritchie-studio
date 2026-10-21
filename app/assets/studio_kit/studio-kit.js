/* The Studio kit's script (docs/agents/system/client-app-host.md, "The Studio
   template"). The shared client-app host serves it at /_studio/kit/<version>/
   on every app and loads it from the page's <head>, so it runs before the
   first paint and the page never flashes the wrong theme.

   Two jobs, and no other:
     1. the theme: `dark` on <html> (the engine's class-based dark mode), from
        the visitor's choice when one is saved, else the device's setting; the
        navbar's toggle flips it and saves it;
     2. the navbar menu: open and close it, by its button, Escape, or a click
        outside it.

   A file, never inline: the host's CSP is script-src 'self'. Storage can throw
   (a private window, blocked site data), so every read and write is guarded and
   the page still works without it. */
(function () {
  "use strict";

  var KEY = "studio-kit-theme";
  var root = document.documentElement;

  function saved() {
    try { return window.localStorage.getItem(KEY); } catch (e) { return null; }
  }

  function save(value) {
    try { window.localStorage.setItem(KEY, value); } catch (e) { /* nothing to keep it in */ }
  }

  function deviceDark() {
    return !!(window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches);
  }

  function isDark() { return root.classList.contains("dark"); }

  function apply(dark) {
    root.classList.toggle("dark", dark);
    root.style.colorScheme = dark ? "dark" : "light";
    var toggles = document.querySelectorAll("[data-studio-kit-theme-toggle]");
    for (var i = 0; i < toggles.length; i++) {
      toggles[i].setAttribute("aria-pressed", dark ? "true" : "false");
    }
  }

  var choice = saved();
  apply(choice === "dark" || (choice !== "light" && deviceDark()));

  // Follow the device while the visitor has not chosen.
  if (window.matchMedia) {
    var query = window.matchMedia("(prefers-color-scheme: dark)");
    var follow = function (event) { if (!saved()) apply(event.matches); };
    if (query.addEventListener) query.addEventListener("change", follow);
    else if (query.addListener) query.addListener(follow);
  }

  function menuParts() {
    var button = document.querySelector("[data-studio-kit-menu-toggle]");
    var panel = button && document.getElementById(button.getAttribute("aria-controls"));
    return panel ? { button: button, panel: panel } : null;
  }

  function setMenu(open, focusButton) {
    var parts = menuParts();
    if (!parts) return;
    parts.panel.hidden = !open;
    parts.button.setAttribute("aria-expanded", open ? "true" : "false");
    if (!open && focusButton) parts.button.focus();
  }

  function wire() {
    apply(isDark());

    document.addEventListener("click", function (event) {
      var target = event.target;
      if (!(target instanceof Element)) return;

      if (target.closest("[data-studio-kit-theme-toggle]")) {
        var dark = !isDark();
        apply(dark);
        save(dark ? "dark" : "light");
        return;
      }

      var parts = menuParts();
      if (!parts) return;
      if (target.closest("[data-studio-kit-menu-toggle]")) {
        setMenu(parts.panel.hidden, false);
      } else if (!parts.panel.hidden && !parts.panel.contains(target)) {
        setMenu(false, false);
      }
    });

    document.addEventListener("keydown", function (event) {
      var parts = menuParts();
      if (event.key === "Escape" && parts && !parts.panel.hidden) setMenu(false, true);
    });
  }

  if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", wire);
  else wire();
})();
