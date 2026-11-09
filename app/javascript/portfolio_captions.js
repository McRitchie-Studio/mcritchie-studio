// The /websites Portfolio caption follows the open app (app/views/websites/index.html.erb).
//
// The engine carousel (studio/_carousel) marks its open slide data-current and
// rewrites the mark on every move: an arrow, a dot, a key, a swipe, autoplay.
// A caption inside a slide would ride the slide's 3D move, so the page keeps one
// caption per app in a single stack under the row, and this marks the open
// app's caption data-current (the CSS cross-fades it in place) and hides the
// rest from assistive tech. The open card is matched to its caption by the
// card link's href; a looping spotlight's seam copies are aria-hidden and skipped.
//
// Installed from the document, so it is inert on every other page and needs no
// reinstall after a Turbo visit.

const OPEN_CARD = ".carousel-slide[data-current]:not([aria-hidden='true']) [data-portfolio-card]";

// The caption to show for the open card's href, or null.
export function captionFor(captions, href) {
  return captions.find((caption) => caption.dataset.portfolioUrl === href) || null;
}

export function sync(stage) {
  const card = stage.querySelector(OPEN_CARD);
  if (!card) return;
  const captions = Array.from(stage.querySelectorAll("[data-portfolio-captions] [data-portfolio-url]"));
  const open = captionFor(captions, card.getAttribute("href"));
  if (!open) return;
  for (const caption of captions) {
    const isOpen = caption === open;
    caption.toggleAttribute("data-current", isOpen);
    if (isOpen) caption.removeAttribute("aria-hidden");
    else caption.setAttribute("aria-hidden", "true");
  }
}

function install() {
  document.querySelectorAll("[data-portfolio-stage]").forEach((stage) => {
    if (stage.portfolioCaptions) return;
    const track = stage.querySelector(".carousel-track");
    if (!track) return;
    stage.portfolioCaptions = new MutationObserver(() => sync(stage));
    stage.portfolioCaptions.observe(track, { subtree: true, attributes: true, attributeFilter: ["data-current"] });
    sync(stage);
  });
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:load", install);
  if (document.readyState !== "loading") install();
  else document.addEventListener("DOMContentLoaded", install);
}
