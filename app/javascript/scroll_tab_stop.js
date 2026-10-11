// A region that can scroll sideways is a tab stop only while it does scroll.
//
// Usage:
//   <div class="overflow-x-auto" tabindex="0" data-scroll-tab-stop> … </div>
//
// The region is served WITH its tabindex, so it is reachable with JavaScript off.
// Here the tabindex is taken away while the content fits and put back when it
// does not: on load, when the region changes size, and when a picture inside it
// finishes loading (which changes the content's width, not the region's).
// First use: the logo gallery's guide plates (app/views/logos/show.html.erb).

// True when the region's content is wider than the region.
export function scrolls(region) {
  return region.scrollWidth > region.clientWidth;
}

export function syncTabStop(region) {
  if (scrolls(region)) region.setAttribute("tabindex", "0");
  else region.removeAttribute("tabindex");
}

const watched = new WeakSet();

export function installScrollTabStops(root = document) {
  root.querySelectorAll("[data-scroll-tab-stop]").forEach((region) => {
    if (!watched.has(region)) {
      watched.add(region);
      new ResizeObserver(() => syncTabStop(region)).observe(region);
      region.querySelectorAll("img").forEach((img) => img.addEventListener("load", () => syncTabStop(region)));
    }
    syncTabStop(region);
  });
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:load", () => installScrollTabStops());
  if (document.readyState !== "loading") installScrollTabStops();
}

// The logo gallery shows a light and a dark guide drawing and lets the hub theme (html.dark) pick one by CSS, so a
// change of theme swaps the drawing without resizing the region: check every region again when the root's class
// changes.
if (typeof document !== "undefined" && typeof MutationObserver !== "undefined") {
  new MutationObserver(() => installScrollTabStops()).observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
}
