// The /build gallery's hover loops: a card's short motion clip plays over its
// still while a mouse rests on the card or the keyboard focuses it.
//
// Usage (app/views/build/_gallery_card.html.erb):
//   <a data-gallery-motion …>
//     <img …>
//     <video data-gallery-motion-video muted loop playsinline preload="none" …>
//   </a>
//
// Never on touch (a tap opens the app), never under prefers-reduced-motion, and
// the video loads nothing until it is asked to play. It is marked
// data-playing only once it really plays, so a slow load shows the still rather
// than a blank box; the template fades it in on that attribute.
// Delegated from the document, so it is inert on every other page and needs no
// reinstall after a Turbo visit.

// Whether a pointer or focus event should start the loop.
export function shouldPlay({ kind, pointerType, focusVisible, reducedMotion }) {
  if (reducedMotion) return false;
  if (kind === "pointer") return pointerType === "mouse";
  if (kind === "focus") return Boolean(focusVisible);
  return false;
}

function reducedMotion() {
  return typeof window !== "undefined" && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
}

function videoOf(card) {
  return card && card.querySelector("[data-gallery-motion-video]");
}

export function play(card) {
  const video = videoOf(card);
  if (!video) return;
  const started = video.play();
  if (started && typeof started.catch === "function") started.catch(() => {});
}

export function stop(card) {
  const video = videoOf(card);
  if (!video) return;
  video.pause();
  video.currentTime = 0;
  video.removeAttribute("data-playing");
}

function cardFrom(target) {
  return target && typeof target.closest === "function" ? target.closest("[data-gallery-motion]") : null;
}

if (typeof document !== "undefined" && !window.__galleryMotionInstalled) {
  window.__galleryMotionInstalled = true;

  document.addEventListener("pointerover", (event) => {
    const card = cardFrom(event.target);
    if (!card || card.contains(event.relatedTarget)) return;
    if (shouldPlay({ kind: "pointer", pointerType: event.pointerType, reducedMotion: reducedMotion() })) play(card);
  });
  document.addEventListener("pointerout", (event) => {
    const card = cardFrom(event.target);
    if (card && !card.contains(event.relatedTarget)) stop(card);
  });
  document.addEventListener("focusin", (event) => {
    const card = cardFrom(event.target);
    if (card && shouldPlay({ kind: "focus", focusVisible: card.matches(":focus-visible"), reducedMotion: reducedMotion() })) play(card);
  });
  document.addEventListener("focusout", (event) => {
    const card = cardFrom(event.target);
    if (card && !card.contains(event.relatedTarget)) stop(card);
  });
  // Media events do not bubble; catch them on the way down.
  document.addEventListener("playing", (event) => {
    if (event.target.matches && event.target.matches("[data-gallery-motion-video]")) event.target.setAttribute("data-playing", "");
  }, true);
}
