const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors } = require("./helpers");

// [e2e] The first-name ask, in a real browser.
//
// The Ruby suites prove the server ARMS the modal and the write lands. Only this
// one proves the part that has bitten before: that the Alpine component actually
// MOUNTS and its save round-trips. A modal whose x-data fails to parse still
// renders its markup, so every server-side assertion stays green while the user
// sees nothing — which is why this walk exists rather than a template assertion.
//
// Each spec signs in as its OWN seeded nameless account. The admin is no use
// here: User derives first_name from name (set_name_parts), so a named account
// already has one and is never asked.

test("a new account is asked for a first name and can save it", async ({ page }) => {
  const { pageErrors, report } = watchPageErrors(page);

  await loginWithMagicLink(page, "newcomer@test.com");

  // The modal is opened by the layout on arrival, not by any click.
  const field = page.locator("#onboarding-first-name");
  await field.waitFor({ state: "visible" });

  // Focused on open — the field is the only thing to do on this screen, and the
  // HTML autofocus attribute does nothing for a modal mounted from a template
  // after the document parsed.
  await expect(field).toBeFocused();

  await field.fill("Alex");
  await page.getByRole("button", { name: "Save and continue" }).click();

  // The step closes itself once the server confirms the write.
  await field.waitFor({ state: "hidden" });

  // And the ask is over — a reload must not ask again, which is what proves the
  // value actually persisted rather than the modal merely being dismissed.
  await page.reload();
  await expect(page.locator("#onboarding-first-name")).toHaveCount(0);

  expect(pageErrors, report()).toEqual([]);
});

// REGRESSION GUARD — the bug review caught, and the assertion my first pass got
// wrong.
//
// Handlers attach to `document`, which SURVIVES a Turbo Drive body replacement;
// the emitted script does not. So a handler from the page that armed the modal
// kept firing on later pages whose server render contains no arming block, and
// re-asked a user who had just answered — on every navigation, for the life of
// the tab.
//
// WHY THIS NEEDS ITS OWN SPEC, AND WHY IT WAITS. The spec above reloads and
// asserts toHaveCount(0) — which fires the instant reload() resolves on `load`,
// while Alpine is a `defer` script that initializes AFTERWARDS. It therefore
// passed whether the modal never opened OR opened 200ms later, which is exactly
// the bug. So this one navigates the way a user does (an in-page Turbo link, not
// a reload), waits for the store to EXIST — the point past which the buggy build
// had already re-opened — and only then asserts absence.
test("answering the ask survives a Turbo navigation", async ({ page }) => {
  await loginWithMagicLink(page, "newcomer-turbo@test.com");

  const field = page.locator("#onboarding-first-name");
  await field.waitFor({ state: "visible" });
  await field.fill("Alex");
  await page.getByRole("button", { name: "Save and continue" }).click();
  await field.waitFor({ state: "hidden" });

  // A real in-page navigation, which is what leaves `document` handlers alive.
  await page.getByRole("link", { name: "McRitchie Studio" }).first().click();

  // Wait past the moment the buggy build re-opened it, rather than asserting
  // into the gap before Alpine has run.
  await page.waitForFunction(() => window.Alpine && Alpine.store && Alpine.store("modals"));
  await page.waitForTimeout(600);

  await expect(page.locator("#onboarding-first-name")).toHaveCount(0);
  // The server must also agree the ask is over — the marker the handler reads.
  await expect(page.locator("#onboarding-ask-first-name")).toHaveCount(0);
});

// Its OWN account: the spec above answers the ask, which mutates that user for
// the rest of the run (the seed happens once, at webServer boot).
test("a new account can skip, and is asked again in a later session", async ({ page, context }) => {
  await loginWithMagicLink(page, "newcomer-skip@test.com");

  const field = page.locator("#onboarding-first-name");
  await field.waitFor({ state: "visible" });

  await page.getByRole("button", { name: "Skip for now" }).click();
  await field.waitFor({ state: "hidden" });

  // Skipping is session-scoped: not now, not never. Within THIS session it stays
  // gone even across a navigation.
  await page.reload();
  await expect(page.locator("#onboarding-first-name")).toHaveCount(0);

  // A LATER session asks again — the field is still blank. This is the assertion
  // that would fail if the skip had been written to the user instead of the
  // session, and it is the reason the skip is not a column.
  await context.clearCookies();
  await loginWithMagicLink(page, "newcomer-skip@test.com");
  await page.locator("#onboarding-first-name").waitFor({ state: "visible" });
});
