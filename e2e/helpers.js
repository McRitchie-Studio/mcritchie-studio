async function loginWithMagicLink(page, email) {
  await page.goto("/signin");
  await page.fill('input[name="email"]', email);

  await Promise.all([
    page.waitForResponse(
      (response) => response.url().includes("/magic_link") && response.request().method() === "POST" && response.ok()
    ),
    page.click('form:has(input[name="email"]) button[type="submit"]'),
  ]);

  let magicLink;
  for (let attempt = 0; attempt < 10; attempt += 1) {
    const inbox = await page.request.get("/_studio/local_emails.json").then((r) => r.json());
    magicLink = inbox.deliveries.find((item) => item.to === email && item.action_url);
    if (magicLink) break;
    await page.waitForTimeout(200);
  }

  if (!magicLink) {
    throw new Error(`No magic link captured for ${email}`);
  }

  const url = new URL(magicLink.action_url, page.url()).pathname;
  await page.goto(url);
  if (new URL(page.url()).pathname !== "/") {
    await page.waitForURL("/", { timeout: 5_000 }).catch(async () => {
      if (new URL(page.url()).pathname === "/") return;
      await page.locator("#magic-consume-form").evaluate((form) => {
        if (typeof form.requestSubmit === "function") form.requestSubmit();
        else form.submit();
      });
      await page.waitForURL("/");
    });
  }
}

// The live-broadcast family's shared "the page stayed clean" watcher.
//
// WHAT IT ASSERTS IS UNCHANGED. `pageErrors` collects exactly what the ten
// hand-rolled copies of this block collected — uncaught page errors plus
// console.error output — and every caller still asserts
// `expect(pageErrors).toHaveLength(0)`. Nothing here relaxes that.
//
// WHAT IT ADDS IS THE URL. Chromium's console text for a failed subresource is
// literally "Failed to load resource: the server responded with a status of 404
// ()" — it carries NO url. That is why this family was un-diagnosable from a CI
// log: the assertion said a resource 404'd and could not say WHICH, the Rails
// request log is not captured in the job output, and the failure does not
// reproduce locally (a clean shard-1 run passes 29/29 with zero 4xx in every
// trace). So `report()` pairs the console lines with the actual failing
// requests, and the next failure names the resource in the assertion message.
//
// `failures` is DIAGNOSTIC ONLY and is deliberately never asserted on: a
// request that 404s without producing a console error is not this assertion's
// business, and folding it into the condition would change what the family
// guards.
//
// ---------------------------------------------------------------------------
// THE COLLECTOR IS SCOPED TO THE APPLICATION ORIGIN. Added 2026-08-13 for
// /tasks/e2e-collector-catches-third-party.
//
// WHAT WENT WRONG. This family went RED on a diff that touched no JS, no views
// and no e2e files, because the collector had swallowed THREE EXTERNAL 404s —
// a Montserrat woff2 from fonts.gstatic.com, and app.sprintful.com. Re-running
// the same SHA went green. The spec's verdict depended on whether a CDN
// answered, which is a test that fails for reasons unrelated to the code under
// test. The cost is not the one re-run: it is that a red which means nothing
// trains everyone to re-run reds, and eventually to wave through a real one.
//
// WHY AN ORIGIN ALLOWLIST AND NOT A HOSTNAME OR TEXT MATCH. The obvious fix is
// to drop messages mentioning `fonts.gstatic.com`. That is a DENY-LIST, and its
// default answer for an unlisted host is "count it" — which sounds safe until
// you notice it makes the NEXT third-party host a fresh red, so the deny-list
// only ever ends the flake it was written for. Worse, the console text for a
// failed subresource is `Failed to load resource: the server responded with a
// status of 404 ()` and carries NO url at all, so a text rule cannot even see
// the host it would be matching. An ORIGIN allowlist inverts the default: a
// message counts as OURS unless it is provably attributable to an origin we
// never navigated to. Unknown input lands on "ours", which is the safe
// direction for an error collector.
//
// WHERE THE ORIGIN COMES FROM. `msg.location().url` — the resource the browser
// was loading, which is exactly the fact the console TEXT is missing. The
// allowlist is the document's own origin, learned lazily from `page.url()` at
// event time (so a spec that navigates somewhere else keeps working), plus any
// origins a caller passes explicitly.
//
// EVERY UNATTRIBUTABLE CASE COUNTS. No location, an empty url, a `data:` or
// `blob:` url, or an allowlist we could not seed because the page never
// navigated — all of them fall through to `pageErrors`. There is no `else` that
// guesses in the permissive direction.
//
// `pageerror` IS NOT SCOPED AT ALL, deliberately. An uncaught exception carries
// no origin on Playwright's public surface, and this defect was never about
// uncaught exceptions — it was about subresource 404s, which arrive as console
// errors. Scoping it would mean parsing origins out of a stack trace, i.e.
// guessing, in exchange for silencing a class of failure nobody has observed.
//
// THE COST, STATED RATHER THAN HIDDEN: an application bug that surfaces only
// from inside a third-party script is now invisible to this collector. That is
// the narrow, deliberate price of scoping by origin, and it is a far smaller
// hole than a collector whose verdict is a coin flip on CDN weather.
//
// Both directions are pinned by e2e/page_error_collector.spec.js: a
// third-party 404 is ignored, and a SAME-ORIGIN 404 with byte-identical console
// text is still caught. A text-matching implementation cannot pass both.

// The origin of `value`, or null when it has none we can trust. Only http(s)
// gets an origin: `data:`, `blob:` and `about:blank` all stringify to useful-
// looking values (`"null"` among them) that must never seed or match the
// allowlist.
function httpOrigin(value) {
  try {
    const url = new URL(String(value));
    return url.protocol === "http:" || url.protocol === "https:" ? url.origin : null;
  } catch {
    return null;
  }
}

function watchPageErrors(page, { allowOrigins = [] } = {}) {
  const pageErrors = [];
  const failures = [];
  const ignored = [];

  // Origins whose failures count as OURS.
  const ours = new Set();
  for (const origin of allowOrigins.map(httpOrigin)) {
    if (origin) ours.add(origin);
  }

  // Learned at event time rather than at attach time: `watchPageErrors(page)`
  // is called before some callers navigate, and `page.url()` is `about:blank`
  // until the first commit. Reading it per-event means the app origin is known
  // by the time any page-generated message can exist. Main-frame only — a
  // `framenavigated` listener would enrol a third-party IFRAME's origin, which
  // is the fail-open shape this whole change exists to remove.
  const learnDocumentOrigin = () => {
    const origin = httpOrigin(page.url());
    if (origin) ours.add(origin);
  };

  // True ONLY for a message we can positively attribute to an origin outside
  // the allowlist. An empty allowlist means we never saw a document, so
  // nothing is third-party yet and everything counts.
  const isThirdParty = (origin) => origin !== null && ours.size > 0 && !ours.has(origin);

  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => {
    if (msg.type() !== "error") return;
    learnDocumentOrigin();

    const location = msg.location();
    const origin = httpOrigin(location && location.url);
    if (isThirdParty(origin)) {
      ignored.push(`${origin} :: ${msg.text()}`);
      return;
    }

    pageErrors.push(msg.text());
  });

  page.on("response", (res) => {
    if (res.status() >= 400) {
      failures.push(`${res.status()} ${res.request().method()} ${res.url()}`);
    }
  });
  page.on("requestfailed", (req) => {
    const reason = req.failure() ? req.failure().errorText : "unknown";
    failures.push(`REQUEST FAILED ${req.method()} ${req.url()} :: ${reason}`);
  });

  const report = () => {
    const lines = [...pageErrors];
    if (failures.length) {
      lines.push("", `failing requests (${failures.length}) — the resource behind the console text:`);
      failures.forEach((f) => lines.push(`  ${f}`));
    }
    // Shown, never asserted on. A third-party failure is not this assertion's
    // business, but hiding it entirely would make "the CDN was down" look
    // identical to "nothing happened" the next time someone reads a trace.
    if (ignored.length) {
      lines.push("", `ignored (${ignored.length}) — third-party origins, not counted as app errors:`);
      ignored.forEach((line) => lines.push(`  ${line}`));
    }
    return lines.join("\n");
  };

  return { pageErrors, failures, ignored, report };
}

module.exports = { loginWithMagicLink, watchPageErrors };
