const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// task hub-adopts-link-preview (studio-engine 0.82, docs/LINK_PREVIEW.md).
// The happy path: an admin reaches /admin/link_preview from the hub's own admin
// menu, edits the default description beside the live card, saves, and a preview
// fetcher carrying iMessage's real user agent then reads the edit from a slim page
// under Apple's 1 MiB limit. The edit is cleared at the end, so the drafted
// default answers again for every other spec.
const IMESSAGE_UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_11_1) AppleWebKit/601.2.4 (KHTML, like Gecko) " +
  "Version/9.0.1 Safari/601.2.4 facebookexternalhit/1.1 Facebot Twitterbot/1.0";

test("admin edits the default link preview and a preview fetcher reads it", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");

  await expect(page.locator('a[href="/admin/link_preview"]').first()).toBeAttached();
  await page.goto("/admin/link_preview");

  const edited = `E2E studio description ${Date.now()}`;
  const description = page.locator('textarea[name="site_identity[description]"]');
  await description.fill(edited);
  // The live card repaints before anything is saved.
  await expect(page.locator("[data-link-preview-card-description]")).toHaveText(edited);

  await page.getByRole("button", { name: "Save" }).click();
  await expect(page.getByText("Link-preview defaults updated.")).toBeVisible();

  try {
    const response = await page.request.get("/packages", { headers: { "User-Agent": IMESSAGE_UA } });
    expect(response.status()).toBe(200);
    expect(response.headers()["x-studio-link-preview"]).toBe("slim");
    const body = await response.text();
    expect(Buffer.byteLength(body)).toBeLessThan(1_048_576);
    expect(body).not.toMatch(/<script/i);
    expect(body).toContain(`<meta property="og:description" content="${edited}">`);
    expect(body).toMatch(/<meta property="og:image" content="[^"]+\/og\.png">/);
  } finally {
    await page.goto("/admin/link_preview");
    await page.locator('textarea[name="site_identity[description]"]').fill("");
    await page.getByRole("button", { name: "Save" }).click();
    await expect(page.getByText("Link-preview defaults updated.")).toBeVisible();
  }
});
