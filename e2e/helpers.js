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

module.exports = { loginWithMagicLink };
