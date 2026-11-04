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
    // Log out lives in the link sidebar; the bar draws none of its own.
    const navbarLogout = controls.filter((control) => control.name === "logout");

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
      navbarLogout,
    };
  });
}

async function expectNavbarContained(page) {
  const metrics = await navbarMetrics(page);
  const message = JSON.stringify(metrics, null, 2);

  expect(metrics.documentOverflow, message).toBeLessThanOrEqual(1);
  expect(metrics.offscreen, message).toEqual([]);
  expect(metrics.navbarLogout, message).toEqual([]);
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

  const name = page.locator("header [data-nav-account] [data-nav-name]");
  await expect(name).toBeVisible();
  await expect(name).toHaveText(/\S/);
  const box = await name.boundingBox();
  // Wider than a letter: a 1px screen-reader box is no name on screen.
  expect(box.width).toBeGreaterThan(16);
  expect(box.height).toBeGreaterThan(8);
  expect(box.x + box.width).toBeLessThanOrEqual(PHONE.width);
  await expectNavbarContained(page);

  // The name costs the bar no room: a short name and a long one leave the account
  // control one width and the header one height, so the brand wraps no sooner. (The
  // height itself depends on the font, so measure only once Montserrat has loaded:
  // CI once read 161px with the fallback face, which wraps the brand, and 129px a
  // moment later.) The control's width is the font-independent half of the claim,
  // so it bites on any machine.
  await page.evaluate(() => document.fonts.ready);
  const header = page.locator("header.nav-shell");
  const account = page.locator("header [data-nav-account]");
  const withName = (await header.boundingBox()).height;
  const accountWithName = (await account.boundingBox()).width;
  for (const text of ["A", "Maximiliano-Bartholomew"]) {
    await name.evaluate((element, value) => { element.textContent = value; }, text);
    expect((await account.boundingBox()).width, text).toBe(accountWithName);
    expect((await header.boundingBox()).height, text).toBe(withName);
  }
  await expect(page.locator(`${PHONE_ROW} [data-link-sidebar-trigger]`)).toBeVisible();
  await expect(page.locator(".nav-phone-tools")).toBeHidden();
});

// 53px: the 2.25rem cog, py-2 and the 1px border. It was 69px while the account
// column carried a Log out row under the name (task navbar-first-name-only).
test("a signed-in phone header is 53px tall once scrolled", async ({ page }) => {
  await page.setViewportSize(PHONE);
  await page.goto("/tasks");
  await page.evaluate(() => window.scrollTo(0, 600));

  const header = page.locator("header.nav-shell");
  await expect(header).toHaveClass(/is-scrolled/);
  await expect.poll(async () => (await header.boundingBox()).height).toBe(53);

  // The row is gone; its cog and theme toggle are in the bar, with the name.
  await expect(page.locator(PHONE_ROW)).toBeHidden();
  await expect(page.locator(".nav-phone-tools [data-link-sidebar-trigger]")).toBeVisible();
  await expect(page.locator(".nav-phone-tools button[title='Toggle theme']")).toBeVisible();
  const name = page.locator("header [data-nav-account] [data-nav-name]");
  await expect(name).toBeVisible();
  const avatar = await page.locator("header [data-nav-account]").boundingBox();
  expect(avatar.x + avatar.width).toBeLessThanOrEqual(PHONE.width);

  await page.locator(".nav-phone-tools [data-link-sidebar-trigger]").click();
  await expect(page.locator(".nav-phone-tools [data-link-sidebar-trigger]")).toHaveAttribute("aria-expanded", "true");
});

// THE ACCOUNT ROW BELOW 768PX (task hub-phone-account-row). Every width the phone
// rules serve, from the narrowest phone to the last width below md.
const PHONE_WIDTHS = [320, 390, 700, 767];

// What the highlight does to the three. The name is found by its text and size,
// not by a hook, so this answers for whichever element draws the name on screen:
// a separate span beside the control went unlit, and the spec read that as red.
const accountLight = (page) => page.evaluate(() => {
  const header = document.querySelector("header.nav-shell");
  const probe = document.createElement("span");
  probe.style.color = "var(--color-primary)";
  document.body.appendChild(probe);
  const primary = getComputedStyle(probe).color;
  probe.remove();
  return {
    primary,
    glow: getComputedStyle(header.querySelector("[data-nav-account] > [aria-hidden] > *")).boxShadow,
  };
});

async function shownName(page) {
  const text = (await page.locator("header [data-nav-name]").first().textContent()).trim();
  const matches = page.locator("header").getByText(text, { exact: true });
  for (let index = 0; index < await matches.count(); index += 1) {
    const box = await matches.nth(index).boundingBox();
    if (box && box.width > 16) return matches.nth(index);
  }
  throw new Error(`no element in the header draws the name "${text}"`);
}

for (const width of [390, 700]) {
  for (const [state, y] of [["at rest", 0], ["scrolled", 1500]]) {
    test(`at ${width}px ${state}, the name lights the avatar and opens what the avatar opens`, async ({ page }) => {
      await page.setViewportSize({ width, height: 844 });
      await page.goto("/tasks");
      await page.evaluate((top) => window.scrollTo(0, top), y);
      if (y) await expect(page.locator("header.nav-shell")).toHaveClass(/is-scrolled/);
      await page.mouse.move(5, 500);
      await expect.poll(async () => (await accountLight(page)).glow).toBe("none");

      const name = await shownName(page);
      await name.hover();
      await expect.poll(async () => (await accountLight(page)).glow).not.toBe("none");
      const lit = await accountLight(page);
      await expect.poll(() => name.evaluate((el) => getComputedStyle(el).color)).toBe(lit.primary);

      await name.click();
      await expect(page.locator("header [data-nav-account]")).toHaveAttribute("aria-expanded", "true");
    });
  }
}

test("below 768px scrolled, the theme toggle draws left of the gear, and both left of the name", async ({ page }) => {
  for (const width of PHONE_WIDTHS) {
    await page.setViewportSize({ width, height: 844 });
    await page.goto("/tasks");
    await page.evaluate(() => window.scrollTo(0, 1500));
    await expect(page.locator(".nav-phone-tools")).toBeVisible();

    const name = await shownName(page);
    const left = async (locator) => (await locator.boundingBox()).x;
    const toggle = await left(page.locator(".nav-phone-tools button[title='Toggle theme']"));
    const gear = await left(page.locator(".nav-phone-tools [data-link-sidebar-trigger]"));
    const nameLeft = await left(name);
    const message = JSON.stringify({ width, toggle, gear, nameLeft });
    expect(toggle, message).toBeLessThan(gear);
    expect(gear, message).toBeLessThan(nameLeft);
  }
});

// Each band, at rest and scrolled: nothing wraps or leaves the screen, and the bar
// still collapses. A wrapped name or brand shows as a taller bar than the band's.
test("the signed-in rail holds at every width, at rest and scrolled", async ({ page }) => {
  for (const width of [...PHONE_WIDTHS, 768, 820, 1024, 1280, 1440]) {
    await page.setViewportSize({ width, height: 844 });
    await page.goto("/tasks");
    await page.evaluate(() => document.fonts.ready);
    const header = page.locator("header.nav-shell");
    const rest = await header.boundingBox();

    for (const y of [0, 1500]) {
      await page.evaluate((top) => window.scrollTo(0, top), y);
      if (y) await expect(header).toHaveClass(/is-scrolled/);
      // The header's own overflow, not the document's: the board's filter bar is
      // wider than a 320px phone, and that is the page's, not the rail's.
      const metrics = await navbarMetrics(page);
      const message = JSON.stringify({ width, y, metrics }, null, 2);
      const headerOverflow = await header.evaluate((el) => el.scrollWidth - el.clientWidth);
      expect(headerOverflow, message).toBeLessThanOrEqual(1);
      expect(metrics.offscreen, message).toEqual([]);
      const name = await (await shownName(page)).boundingBox();
      expect(name.height, message).toBeLessThanOrEqual(28);
    }

    await expect.poll(async () => {
      const box = await header.boundingBox();
      return box.y + box.height;
    }, { message: `the bar collapses at ${width}px` }).toBeLessThan(rest.y + rest.height);
    if (width < 768) await expect.poll(async () => (await header.boundingBox()).height).toBe(53);
  }
});

// Desktop: the avatar rides the scroll ramp with the logo and title, 40px at
// rest to 32px collapsed, and the first name keeps the rule of 3 against it
// (font size = avatar / 3 / Montserrat's 0.7 cap height).
test("the desktop avatar shrinks on scroll and the name follows it", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/tasks");

  // The name's size as RENDERED: its font size times any transform on the way
  // up. The scroll-driven navbar (studio-engine) shrinks it by transform, so
  // its computed font size stays the resting one while what reads on screen
  // follows the avatar.
  const sizes = () => page.evaluate(() => {
    const name = document.querySelector("header [data-nav-name]");
    const scale = name.getBoundingClientRect().height / parseFloat(getComputedStyle(name).height);
    return {
      avatar: document.querySelector("header [data-nav-account] [aria-hidden] > *").getBoundingClientRect().height,
      name: parseFloat(getComputedStyle(name).fontSize) * scale,
    };
  });

  const rest = await sizes();
  expect(rest.avatar).toBe(40);

  // The theme toggle and gear sit on the name's line, not the top of the row.
  const centres = await page.evaluate(() => {
    const mid = (s) => { const r = document.querySelector(s).getBoundingClientRect(); return r.top + r.height / 2; };
    return {
      avatar: mid("header [data-nav-account] [aria-hidden] > *"),
      name: mid("header [data-nav-name]"),
      toggle: mid("header [data-nav-theme-toggle='desktop']"),
    };
  });
  expect(Math.abs(centres.toggle - centres.avatar), JSON.stringify(centres)).toBeLessThanOrEqual(1);
  expect(Math.abs(centres.name - centres.avatar), JSON.stringify(centres)).toBeLessThanOrEqual(1);
  expect(rest.name).toBeCloseTo(40 / 3 / 0.7, 1);

  await page.evaluate(() => window.scrollTo(0, 1200));
  await expect(page.locator("header.nav-shell")).toHaveClass(/is-scrolled/);
  await expect.poll(async () => (await sizes()).avatar).toBe(32);
  expect((await sizes()).name).toBeCloseTo(32 / 3 / 0.7, 1);
});

// Desktop: moon to gear, gear to name and name to avatar are one gap, measured
// ink to ink (the icons' drawn paths, the name's text box), at rest and scrolled.
test("the desktop controls are evenly spaced", async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 800 });
  await page.goto("/tasks");
  await page.evaluate(() => document.fonts.ready);

  const gaps = () => page.evaluate(() => {
    const ink = (svg) => {
      let left = Infinity, right = -Infinity;
      svg.querySelectorAll("path, circle").forEach((el) => {
        const box = el.getBBox(), m = el.getScreenCTM();
        [box.x, box.x + box.width].forEach((x) => {
          const sx = m.a * x + m.c * box.y + m.e;
          left = Math.min(left, sx);
          right = Math.max(right, sx);
        });
      });
      return [left, right];
    };
    const shown = (list) => [...list].find((el) => el.getBoundingClientRect().width > 0);
    const moon = ink(shown(document.querySelectorAll("header [data-nav-theme-toggle='desktop'] .nav-toggle-icon svg")));
    const gear = ink(shown(document.querySelectorAll("header [data-link-sidebar-trigger] svg")));
    const range = document.createRange();
    range.selectNodeContents(document.querySelector("header [data-nav-name]"));
    const name = range.getBoundingClientRect();
    const avatar = document.querySelector("header [data-nav-account] [aria-hidden] > *").getBoundingClientRect();
    return [gear[0] - moon[1], name.left - gear[1], avatar.left - name.right];
  });

  for (const y of [0, 1200]) {
    await page.evaluate((top) => window.scrollTo(0, top), y);
    if (y) await expect(page.locator("header.nav-shell")).toHaveClass(/is-scrolled/);
    const measured = await gaps();
    measured.forEach((gap) => expect(Math.abs(gap - 12), JSON.stringify(measured)).toBeLessThanOrEqual(1));
  }
});

// THE SCROLL-DRIVEN NAVBAR (studio-engine's navbar_scroll_timeline, which
// config/initializers/studio.rb turns on). From 768px the collapse is the
// browser's: the header keeps one height and its top band scrolls away with the
// page, and its contents shrink by transforms on the page's scroll timeline.
// Nothing runs per frame, so a busy main thread cannot make it stutter.
//
// The hub's own PR runs on the LOCKED engine, which may predate the setting
// (the header then carries no data-nav-timeline); the release's relock is the
// run that exercises the timeline. So each spec asserts the contract of the
// engine it finds: the timeline's when the header opted in, and otherwise the
// --nav-p collapse's, which must still drive the header.
const onTimeline = async (header) => (await header.getAttribute("data-nav-timeline")) !== null;

async function expectNavPCollapse(page, header) {
  await expect(header).not.toHaveAttribute("data-nav-timeline-on", /.*/);
  await page.evaluate(() => window.scrollTo(0, 600));
  await expect.poll(() => header.evaluate((h) => h.style.getPropertyValue("--nav-p"))).toBe("1.0000");
}

test("the desktop navbar collapses on the scroll timeline, with no script per frame", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/tasks");
  await page.evaluate(() => document.fonts.ready);
  const header = page.locator("header.nav-shell");
  if (!(await onTimeline(header))) return expectNavPCollapse(page, header);
  await expect(header).toHaveAttribute("data-nav-timeline-on", "");

  const run = await page.evaluate(async () => {
    const h = document.querySelector("header.nav-shell");
    const probe = [...document.querySelectorAll("h1, h2")].find((e) => !h.contains(e));
    const frame = () => new Promise((r) => requestAnimationFrame(r));
    const writes = [];
    new MutationObserver((ms) => ms.forEach((m) => writes.push(m.attributeName))).observe(h, { attributes: true, attributeFilter: ["style"] });
    const rows = [];
    const read = () => { const r = h.getBoundingClientRect(); rows.push({ box: r.height, bottom: r.bottom, docH: document.documentElement.scrollHeight, top: probe.getBoundingClientRect().top + window.scrollY }); };
    read();
    for (const s of [10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 10, 600, -900]) { window.scrollBy(0, s); await frame(); read(); }
    return { rows, styleWrites: writes.length, navH: getComputedStyle(document.documentElement).getPropertyValue("--nav-h") };
  });

  const boxes = new Set(run.rows.map((r) => r.box));
  expect([...boxes], "the header's box never changes height").toHaveLength(1);
  expect(new Set(run.rows.map((r) => r.docH)).size, "the document never changes height").toBe(1);
  expect(Math.max(...run.rows.map((r) => r.top)) - Math.min(...run.rows.map((r) => r.top)), "the page never moves by itself").toBeLessThanOrEqual(0.5);
  // Collapsed, what shows is the 48px compact bar, and --nav-h says so (an
  // anchor's scroll-margin lands under the bar, not 40px below it).
  expect(Math.round(run.rows[run.rows.length - 2].bottom)).toBe(48);
  expect(Math.round(parseFloat(run.navH))).toBe(48);
  // No script wrote the header's style while it scrolled.
  expect(run.styleWrites, "inline style writes on the header during the scroll").toBe(0);
});

// Below 768px the phone keeps the --nav-p collapse, and widening again goes
// back to the timeline.
test("narrowing to a phone hands the header back to the --nav-p collapse", async ({ page }) => {
  await page.setViewportSize({ width: 1440, height: 900 });
  await page.goto("/tasks");
  const header = page.locator("header.nav-shell");
  if (!(await onTimeline(header))) return expectNavPCollapse(page, header);
  await expect(header).toHaveAttribute("data-nav-timeline-on", "");
  await page.setViewportSize({ width: 390, height: 844 });
  await expect(header).not.toHaveAttribute("data-nav-timeline-on", /.*/);
  await page.evaluate(() => window.scrollTo(0, 400));
  await expect.poll(() => header.evaluate((h) => h.style.getPropertyValue("--nav-p"))).toBe("1.0000");
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.setViewportSize({ width: 1440, height: 900 });
  await expect(header).toHaveAttribute("data-nav-timeline-on", "");
  await expect.poll(() => header.evaluate((h) => h.style.getPropertyValue("--nav-p"))).toBe("");
});
