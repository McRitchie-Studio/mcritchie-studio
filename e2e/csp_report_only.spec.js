// [e2e] hub-report-only-csp: a signed-in page, loaded in full, trips nothing in the
// hub's report-only Content-Security-Policy. The browser fires a
// securitypolicyviolation event (and logs "[Report Only]" to the console) for each
// thing the policy would refuse; a clean page fires none. The init script records
// events from the first byte, so a violation during parse is not missed. The
// control at the end proves the watcher, and the report delivery, bite.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function recordViolations(page) {
  const consoleHits = [];
  page.on("console", (msg) => {
    if (/Content Security Policy|\[Report Only\]/i.test(msg.text())) consoleHits.push(msg.text());
  });
  await page.addInitScript(() => {
    window.__cspViolations = [];
    document.addEventListener("securitypolicyviolation", (e) => {
      window.__cspViolations.push(`${e.effectiveDirective} blocked ${e.blockedURI} at ${e.sourceFile}:${e.lineNumber} ${e.sample}`);
    });
  });
  return consoleHits;
}

test("a signed-in page loads with the report-only policy and zero violations", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  const consoleHits = await recordViolations(page);

  const response = await page.goto("/admin/csp_reports");
  const policy = response.headers()["content-security-policy-report-only"] || "";
  expect(policy).toContain("script-src 'self'");
  expect(policy).toMatch(/'nonce-[^']+'/);
  expect(response.headers()["content-security-policy"]).toBeUndefined();

  await expect(page.getByRole("heading", { name: "CSP reports" })).toBeVisible();
  // Alpine and the module graph have run: the store the body binds exists.
  await page.waitForFunction(() => window.Alpine && window.Alpine.store("devMode") !== undefined);

  const violations = await page.evaluate(() => window.__cspViolations);
  expect(violations).toEqual([]);
  expect(consoleHits).toEqual([]);

  // CONTROL: the watcher sees a violation when there is one. An inline script with
  // no nonce is what the policy refuses; report-only lets it run, and reports it.
  await page.addScriptTag({ content: "window.__cspControlRan = true;" });
  await expect.poll(() => page.evaluate(() => window.__cspViolations.length)).toBeGreaterThan(0);
  expect(await page.evaluate(() => window.__cspControlRan)).toBe(true);

  // And the browser delivered it: report-uri posted it to /csp_reports, which the
  // admin page now lists.
  await expect.poll(async () => {
    const html = await (await page.request.get("/admin/csp_reports?days=1")).text();
    // 'report-sample' quotes the blocked script, so this row is the control's own.
    return html.includes("window.__cspControlRan");
  }, { timeout: 15_000 }).toBe(true);
});
