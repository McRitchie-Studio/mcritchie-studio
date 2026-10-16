// The scroll-driven navbar's two jobs that CSS cannot do (application.css, THE
// SCROLL-DRIVEN NAVBAR). Neither runs per frame.
//
// 1. WHERE THE COLLAPSE STARTS. The collapse is a CSS scroll timeline on the
//    page, so it needs the scroll offset at which the header reaches the top of
//    the window: the height of the bars above it in the page's flow (the
//    environment banner off production; nothing on production). Published as
//    --sd-start on the header on load, on a Turbo visit, and when the bar stack
//    changes size, and only when the number changed.
//
// 2. TAKING THE HEADER OFF THE ENGINE'S SCRIPT. studio-engine's nav-collapse
//    controller writes --nav-p on every scroll frame and toggles the scrolled
//    classes. Where the scroll-driven collapse is on (a browser with scroll
//    timelines, 768px and up) this removes the header's controller attribute,
//    so Stimulus disconnects it and its own stop() clears the inline state it
//    wrote. Below 768px, or in a browser without scroll timelines, the
//    attribute stays (or comes back), and the engine's collapse runs as before.
//
// 3. THE is-scrolled MARKER. The engine's header carries `is-scrolled` past
//    its scroll threshold, and that marker is the navbar's contract for
//    anything that styles or tests a scrolled header. The controller set it;
//    with the controller off, this keeps it, on the controller's own
//    hysteresis (lit past 60px, out under 5px), writing only when it flips.
//    Only the marker: the shadow and the line it used to bring are drawn by
//    the timeline.
const HEADER = "header.nav-shell[data-pin='nav']"
const BARS = "[data-studio-bar-stack]"
const CONTROLLER = "nav-collapse"
const ON = typeof CSS !== "undefined" && CSS.supports && CSS.supports("animation-timeline: scroll()")
const WIDE = window.matchMedia("(min-width: 768px)")

let observer = null
let lit = false

function markScrolled() {
  const el = header()
  if (!el || !scrollDriven()) return
  const y = window.scrollY
  const next = lit ? y > 5 : y > 60
  if (next !== lit || el.classList.contains("is-scrolled") !== next) {
    lit = next
    el.classList.toggle("is-scrolled", next)
  }
}

function header() {
  return document.querySelector(HEADER)
}

export function scrollDriven() {
  return ON && WIDE.matches
}

function publishStart() {
  const el = header()
  if (!el) return
  const bars = document.querySelector(BARS)
  const start = bars && bars.compareDocumentPosition(el) & Node.DOCUMENT_POSITION_FOLLOWING
    ? Math.round(bars.getBoundingClientRect().height)
    : 0
  const value = `${start}px`
  if (el.style.getPropertyValue("--sd-start") !== value) el.style.setProperty("--sd-start", value)
}

// The name's width, for the icon rail's slide. offsetWidth is the layout
// width, which a transform does not change, so it reads the same at any scroll.
function publishNameWidth() {
  const el = header()
  if (!el || !scrollDriven()) return
  const name = el.querySelector("[data-nav-account] > span:first-child")
  if (!name) return
  const width = Math.round(name.offsetWidth * 10) / 10
  const value = `${width}px`
  if (el.style.getPropertyValue("--sd-name-w") !== value) el.style.setProperty("--sd-name-w", value)
}

// Take a header off the engine's controller: the attribute moves aside, so
// Stimulus never connects it (or disconnects it), and the scrolled classes the
// controller would have toggled are cleared.
function detach(el) {
  if (el.getAttribute("data-studio-controller") !== CONTROLLER) return false
  el.setAttribute("data-sd-controller", CONTROLLER)
  el.removeAttribute("data-studio-controller")
  const scrolled = (el.getAttribute("data-nav-collapse-scrolled-class") || "").split(/\s+/).filter(Boolean)
  for (const name of scrolled) el.classList.remove(name)
  return true
}

function assignController() {
  const el = header()
  if (!el) return
  const current = el.getAttribute("data-studio-controller")
  if (scrollDriven()) {
    if (current !== CONTROLLER) return
    detach(el)
    lit = false
    markScrolled()
  } else if (!current && el.getAttribute("data-sd-controller")) {
    el.setAttribute("data-studio-controller", el.getAttribute("data-sd-controller"))
    el.removeAttribute("data-sd-controller")
  }
}

function watch() {
  if (observer) observer.disconnect()
  observer = null
  assignController()
  publishStart()
  publishNameWidth()
  if (document.fonts && document.fonts.ready) document.fonts.ready.then(publishNameWidth)
  const bars = document.querySelector(BARS)
  if (bars && typeof ResizeObserver === "function") {
    observer = new ResizeObserver(publishStart)
    observer.observe(bars)
  }
}

// A Turbo visit or restore renders a new header from the engine's markup. Take
// it off the controller BEFORE it is in the document, so the engine's collapse
// never runs on it, not even for the frames before turbo:load (which Studio's
// page transitions delay).
document.addEventListener("turbo:before-render", (event) => {
  if (!scrollDriven()) return
  const incoming = event.detail && event.detail.newBody && event.detail.newBody.querySelector(HEADER)
  if (incoming) detach(incoming)
})
document.addEventListener("turbo:render", watch)
document.addEventListener("turbo:load", watch)
// Turbo caches the page it leaves; hand the header back to the engine first,
// so a restored page starts from the markup the engine rendered.
document.addEventListener("turbo:before-cache", () => {
  const el = header()
  if (el && el.getAttribute("data-sd-controller")) {
    el.setAttribute("data-studio-controller", el.getAttribute("data-sd-controller"))
    el.removeAttribute("data-sd-controller")
  }
})
WIDE.addEventListener("change", watch)
window.addEventListener("resize", () => { publishStart(); publishNameWidth() }, { passive: true })
window.addEventListener("scroll", markScrolled, { passive: true })
watch()
