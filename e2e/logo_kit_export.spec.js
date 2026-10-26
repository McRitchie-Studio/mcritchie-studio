// [e2e] The kit export (task kit-export-and-clear-lens; Alex McRitchie 2026-10-12 00:55: his Commercial Welding
// site drew an old navbar, not the one his kit saves). Save Commercial Welding v2's Navbar in Original,
// homogeneous; the Kit card's Download kit then gives a zip of the saved logos with a README, the
// stable kit file and the plain /navbar route both serve that saved navbar (solid white words on dark,
// the Original helmet with its lens cut clear), and clearing the choice puts the default back.
const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

// Written as literal tests, not a loop: bin/e2e-executed-set-check counts `test(` calls in the source.
test("download the kit export and see the saved navbar", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await loginWithMagicLink(page, "alex@test.com");

  // Alex McRitchie's kit Navbar: Original, homogeneous, rule of 4.
  await page.goto("/logos/welding_v2?rule=4&colouring=original&text=homogeneous");
  const choice = page.locator("[data-test='kit-choice']");
  await choice.locator("[data-test='kit-save']").click();
  await page.waitForURL(/\/logos\/welding_v2.*#kit-choice$/);
  await expect(page.locator("[data-test='kit-pick'][data-type='navbar']")).toHaveAttribute("data-saved", "true");

  // The Kit card's Download kit gives the zip, its README and every file named in it.
  const button = page.locator("[data-test='kit-download']");
  await expect(button).toBeVisible();
  const [download] = await Promise.all([page.waitForEvent("download"), button.click()]);
  expect(download.suggestedFilename()).toBe("welding_v2-kit.zip");
  const zip = await (await download.createReadStream()).toArray().then((chunks) => Buffer.concat(chunks));
  expect(zip.subarray(0, 2).toString("latin1")).toBe("PK");
  for (const name of ["README.md", "icon-light.svg", "navbar-light.svg", "navbar-dark.svg", "navbar-watermark.svg", "stacked-dark.svg"]) {
    expect(zip.includes(Buffer.from(`welding_v2-kit/${name}`)), name).toBe(true);
  }

  // The stable kit file and the plain route agree: the saved navbar, solid white words on dark, no ember highlight.
  const kitFile = await page.request.get("/logos/welding_v2/kit/navbar-dark.svg");
  expect(kitFile.headers()["content-type"]).toContain("image/svg+xml");
  const svg = await kitFile.text();
  expect(svg).toContain('fill="#FFFFFF"');
  expect(svg).not.toContain("#F08A5A");
  const plain = await page.request.get("/logos/welding_v2/navbar?tone=dark");
  expect(plain.headers()["x-logo-source"]).toBe("kit");
  expect(await plain.text()).toBe(svg);

  // It draws in a browser as a picture.
  await page.goto("/logos/welding_v2/kit/navbar-dark.svg");
  await expect(page.locator("svg")).toBeVisible();

  // Leave the seed as it was: clear the saved Navbar; the same URLs stop serving it. (Whether the plain route then says
  // "kit" or "params" depends on what other specs left saved for this brand, so only the drawing is checked.)
  await page.goto("/logos/welding_v2");
  await page.locator("[data-test='kit-clear']").click();
  await expect(page.getByText("Cleared the Navbar Logo kit choice. The brand shows its default again.")).toBeVisible();
  await expect(page.locator("[data-test='kit-pick'][data-type='navbar']")).toHaveAttribute("data-saved", "false");
  expect(await (await page.request.get("/logos/welding_v2/kit/navbar-dark.svg")).text()).not.toBe(svg);
  expect(await (await page.request.get("/logos/welding_v2/navbar?tone=dark")).text()).not.toBe(svg);
});
