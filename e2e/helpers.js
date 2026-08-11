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
function watchPageErrors(page) {
  const pageErrors = [];
  const failures = [];

  page.on("pageerror", (err) => pageErrors.push(String(err)));
  page.on("console", (msg) => { if (msg.type() === "error") pageErrors.push(msg.text()); });

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
    return lines.join("\n");
  };

  return { pageErrors, failures, report };
}

module.exports = { loginWithMagicLink, watchPageErrors };
