const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const VIEWPORTS = [
  { width: 1366, height: 800 },
  { width: 1024, height: 768 },
  { width: 820, height: 768 },
];

async function navbarMetrics(page) {
  return await page.evaluate(() => {
    const viewportWidth = document.documentElement.clientWidth;
    const documentWidth = Math.max(
      document.documentElement.scrollWidth,
      document.body.scrollWidth
    );
    const header = document.querySelector("header");
    const visible = (element) => {
      const style = window.getComputedStyle(element);
      const rect = element.getBoundingClientRect();
      return style.display !== "none" &&
        style.visibility !== "hidden" &&
        rect.width > 0 &&
        rect.height > 0;
    };

    const selectors = [
      ["username", "[data-nav-name]"],
      ["profile", "[data-nav-account]"],
      ["sidebar", "[data-link-sidebar-trigger]"],
      ["logout", 'a[href="/logout"]'],
    ];

    const controls = selectors.flatMap(([name, selector]) =>
      Array.from(document.querySelectorAll(selector))
        .filter(visible)
        .map((element) => {
          const rect = element.getBoundingClientRect();
          return {
            name,
            text: element.textContent.trim().replace(/\s+/g, " "),
            left: rect.left,
            right: rect.right,
            width: rect.width,
            height: rect.height,
          };
        })
    );

    const headerRect = header ? header.getBoundingClientRect() : null;
    const offscreen = controls.filter((control) =>
      control.left < -1 || control.right > viewportWidth + 1
    );
    const wrappedLogout = controls.filter((control) =>
      control.name === "logout" && control.height > 16
    );

    return {
      viewportWidth,
      documentOverflow: documentWidth - viewportWidth,
      header: headerRect && {
        left: headerRect.left,
        right: headerRect.right,
        width: headerRect.width,
      },
      controls,
      offscreen,
      wrappedLogout,
    };
  });
}

async function expectNavbarContained(page) {
  const metrics = await navbarMetrics(page);
  const message = JSON.stringify(metrics, null, 2);

  expect(metrics.documentOverflow, message).toBeLessThanOrEqual(1);
  expect(metrics.offscreen, message).toEqual([]);
  expect(metrics.wrappedLogout, message).toEqual([]);
  expect(metrics.controls.some((control) => control.name === "username"), message).toBe(true);
  expect(metrics.controls.some((control) => control.name === "profile"), message).toBe(true);
}

test("logged-in navbar controls stay contained at constrained desktop widths", async ({ page }) => {
  await page.setViewportSize(VIEWPORTS[0]);
  await loginWithMagicLink(page, "alex@test.com");

  for (const viewport of VIEWPORTS) {
    await page.setViewportSize(viewport);
    await page.goto("/dashboard");
    await expect(page.locator("[data-nav-name]").first()).toBeVisible();
    await expectNavbarContained(page);
  }
});

// A phone, signed in: the bar names the account, and it collapses to one row.
const PHONE = { width: 390, height: 844 };
const PHONE_ROW = "header.nav-shell > .nav-row ~ div";

test("a signed-in phone header shows the user's name", async ({ page }) => {
  await page.setViewportSize(PHONE);
  await page.goto("/dashboard");

  const name = page.locator("header [data-nav-phone-name]");
  await expect(name).toBeVisible();
  await expect(name).toHaveText(/\S/);
  const box = await name.boundingBox();
  // Wider than a letter: a 1px screen-reader box is no name on screen.
  expect(box.width).toBeGreaterThan(16);
  expect(box.height).toBeGreaterThan(8);
  expect(box.x + box.width).toBeLessThanOrEqual(PHONE.width);
  await expectNavbarContained(page);

  // At rest the header is two rows and the brand keeps one line.
  expect((await page.locator("header.nav-shell").boundingBox()).height).toBe(129);
  await expect(page.locator(`${PHONE_ROW} [data-link-sidebar-trigger]`)).toBeVisible();
  await expect(page.locator(".nav-phone-tools")).toBeHidden();
});

test("a signed-in phone header is 69px tall once scrolled", async ({ page }) => {
  await page.setViewportSize(PHONE);
  await page.goto("/tasks");
  await page.evaluate(() => window.scrollTo(0, 600));

  const header = page.locator("header.nav-shell");
  await expect(header).toHaveClass(/is-scrolled/);
  await expect.poll(async () => (await header.boundingBox()).height).toBe(69);

  // The row is gone; its cog and theme toggle are in the bar, with the name.
  await expect(page.locator(PHONE_ROW)).toBeHidden();
  await expect(page.locator(".nav-phone-tools [data-link-sidebar-trigger]")).toBeVisible();
  await expect(page.locator(".nav-phone-tools button[title='Toggle theme']")).toBeVisible();
  await expect(page.locator("header [data-nav-phone-name]")).toBeVisible();
  await expectNavbarContained(page);

  await page.locator(".nav-phone-tools [data-link-sidebar-trigger]").click();
  await expect(page.locator(".nav-phone-tools [data-link-sidebar-trigger]")).toHaveAttribute("aria-expanded", "true");
});
