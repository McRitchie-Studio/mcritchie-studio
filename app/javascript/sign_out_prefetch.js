// Turbo never prefetches a sign-out.
//
// Turbo 8 prefetches a same-origin link the pointer rests on for 100ms. The
// engine's "Log out" (components/_link_sidebar) is a plain GET to /logout, so a
// pointer that only passed over it signed the browser out: the prefetch ran
// SessionsController#destroy and its Set-Cookie dropped the session, while the
// page on screen still drew the user. Measured in e2e/build_funnel.spec.js (task
// build-funnel-held-message-cause): the cursor left on the claim button rested on
// the menu's Log out, and the admin's next /build message went in signed out.
//
// ApplicationController#refuse_prefetched_sign_out answers any prefetch that
// still reaches the server; this stops Turbo asking at all, so a click on Log
// out is a real visit and never a cached 204.

// The paths whose GET ends the session (the engine's `get "/logout"`).
export const SIGN_OUT_PATHS = Object.freeze([ "/logout" ])

// PURE. Whether `link` (anything with an href) signs out on `origin`.
export function isSignOutLink(link, origin) {
  const href = link && typeof link.getAttribute === "function" ? link.getAttribute("href") : null
  if (!href) return false
  let url
  try {
    url = new URL(href, origin)
  } catch (_error) {
    return false
  }
  return url.origin === origin && SIGN_OUT_PATHS.includes(url.pathname.replace(/\/+$/, "") || "/")
}

// The turbo:before-prefetch listener: cancels the prefetch of a sign-out link.
export function refuseSignOutPrefetch(event, origin = globalThis.location?.origin) {
  if (isSignOutLink(event.target, origin)) event.preventDefault()
}

if (typeof document !== "undefined") {
  document.addEventListener("turbo:before-prefetch", (event) => refuseSignOutPrefetch(event))
}
