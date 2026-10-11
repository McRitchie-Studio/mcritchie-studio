// A page opened with an explicit theme is in that theme from its first paint (task logo-gallery-polish-pass; the
// logo gallery's shared ?context=light|dark|watermark links, where the theme used to arrive 0.7-2.6 s late).
//
// A CLASSIC SCRIPT, not a module, loaded by the hub layout in the <head> right after the engine's pre-paint theme
// script (layouts/studio/_head), and only on a page that names a theme:
//
//   <html data-theme-context="light">   (content_for :html_theme; "dark" also renders class="dark" on the server)
//
// A module is deferred, so it runs after the first paint; a script in the head runs before it. The engine's script
// has just set `dark` from the stored theme; this one stores the page's theme in its place (localStorage 'theme',
// which the engine's store and the moon icon read) and sets the class to match, so the hub stays in that theme
// afterwards, as the Context control's choice does. app/javascript/logo_gallery.js still syncs a Turbo visit.
(function () {
  var root = document.documentElement;
  var theme = root.getAttribute("data-theme-context");
  if (theme !== "light" && theme !== "dark") return;
  try {
    localStorage.setItem("theme", theme);
  } catch (_) {
    // Storage blocked: the class below still sets this page's theme.
  }
  root.classList.toggle("dark", theme === "dark");
})();
