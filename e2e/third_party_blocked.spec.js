const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// [e2e][control] A THIRD PARTY MAY NOT DECIDE WHETHER THIS SUITE FINISHES.
//
// These two exist because the fix they guard is one line inside a shared helper
// (`blockThirdPartyRequests`), and deleting it would look like a simplification.
// The failure it prevents does not reproduce on a laptop — it needs a runner
// that cannot reach the third party — so without a control here the next author
// removes it and learns why nine months later, from a red on an unrelated PR.
//
// WHAT WENT WRONG. `devops_key_preservation.spec.js` timed out at 30s inside
// `page.goto` with the call log `waiting until "load"`, 46 other specs passing
// and no app code in the diff. `load` waits for every subresource; the magic
// link consume lands on `/`; `/` is `landing#index`; and that page carries
// `<script src="https://app.sprintful.com/widget/v1.js">`. Stalling every
// non-app origin locally reproduced it byte for byte, 3/3, and refusing them
// made it 0/3 at ~0.2s. Full measurement in e2e/helpers.js.
//
// BOTH DIRECTIONS ARE LOAD-BEARING, and the reason is the same one
// page_error_collector.spec.js gives for its pair: a blanket blocker passes the
// first assertion and breaks the app's own stylesheet, which would surface as
// 50 unrelated specs failing on layout. Only a rule scoped BY ORIGIN passes
// both.

test("a cross-origin subresource is refused rather than waited on", async ({ page }) => {
  // The app's origin is learned from the FIRST navigation, not read off
  // `page.url()` per event: before the first commit that is "about:blank", which
  // has no origin, and a comparison against nothing calls every request foreign.
  let appOrigin = null;
  const attempted = [];
  const succeeded = [];
  page.on("request", (request) => {
    const target = originOf(request.url());
    if (request.isNavigationRequest()) appOrigin ||= target;
    if (!request.isNavigationRequest() && appOrigin && target && target !== appOrigin) {
      attempted.push(request.url());
    }
  });
  page.on("response", (response) => {
    const target = originOf(response.url());
    if (appOrigin && target && target !== appOrigin) succeeded.push(`${response.status()} ${response.url()}`);
  });

  await loginWithMagicLink(page, "alex@test.com");
  await expect(page).toHaveURL(/\/$/);

  // NOT VACUOUS: the signed-in landing must still ASK for something off-origin,
  // or this control is asserting about a page with no third party on it. If the
  // widget is ever removed from app/views/landing/index.html.erb, retire this
  // pair rather than letting it pass on an empty set.
  expect(attempted.join("\n")).toContain("sprintful.com");
  expect(succeeded, `cross-origin responses that got through:\n${succeeded.join("\n")}`).toEqual([]);
});

test("a same-origin subresource still loads", async ({ page }) => {
  let appOrigin = null;
  const ours = [];
  page.on("request", (request) => {
    if (request.isNavigationRequest()) appOrigin ||= originOf(request.url());
  });
  page.on("response", (response) => {
    if (appOrigin && originOf(response.url()) === appOrigin && response.status() === 200) {
      ours.push(new URL(response.url()).pathname);
    }
  });

  await loginWithMagicLink(page, "alex@test.com");

  // The stylesheet is the one asset whose absence this repo has already paid
  // for: without it every page dies in the view layer. A blocker scoped to
  // anything wider than "not our origin" kills it here, loudly, instead of in
  // 50 specs whose subject is layout.
  expect(ours.some((path) => path.includes("tailwind"))).toBe(true);
});

function originOf(value) {
  try {
    const url = new URL(String(value));
    return url.protocol === "http:" || url.protocol === "https:" ? url.origin : null;
  } catch {
    return null;
  }
}
