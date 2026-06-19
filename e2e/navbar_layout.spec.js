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
      ["username", "[data-username-display]"],
      ["profile", "[data-profile-image-toggle]"],
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
    await expect(page.locator("[data-username-display]").first()).toBeVisible();
    await expectNavbarContained(page);
  }
});
