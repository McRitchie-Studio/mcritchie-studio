const { test, expect } = require("@playwright/test");
const { loginWithMagicLink, watchPageErrors } = require("./helpers");

// The task board's chrome (tasks/_board) toasts, recounts and animates through the
// engine board inside it, reached by window.HubEngineBoard (board/engine_board).
// The page's importmap pins "studio/board", so the engine publishes the board's
// scope through scopeFor and the chrome never asks Alpine.$data for it.
test("the task board's chrome reaches the engine board through the scope the engine publishes", async ({ page }) => {
  const errors = watchPageErrors(page);
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/tasks");
  await page.waitForSelector("[data-test='kanban-board'][data-alpine-ready]");

  const facts = await page.evaluate(async () => {
    const chrome = document.querySelector("[data-test='kanban-board']");
    const section = chrome.querySelector("[data-test='studio-board']");
    const imports = JSON.parse(document.querySelector('script[type="importmap"]').textContent).imports;
    const pinned = typeof imports["studio/board"] === "string";
    const reach = window.HubEngineBoard;
    const scope = reach.scope(section);

    // Count what the chrome asks Alpine for from here on: only a read of the
    // board's own section counts.
    const chromeScope = window.Alpine.$data(chrome);
    const readOffElement = window.Alpine.$data;
    let sectionReads = 0;
    window.Alpine.$data = function (element) {
      if (element === section) sectionReads += 1;
      return readOffElement.apply(this, arguments);
    };
    chromeScope.boardToast("Reached the engine board", "success");
    chromeScope.boardRefreshCounts();
    window.Alpine.$data = readOffElement;

    return {
      pinned,
      published: reach.published,
      scopeIsABoard: !!scope && ["toast", "updateCounts", "animateCardExit"].every((name) => typeof scope[name] === "function"),
      sameAsScopeFor: pinned && (await (await import("studio/board")).scopeFor(section)) === scope,
      sectionReads,
    };
  });

  expect(facts.pinned, "the page's importmap pins studio/board").toBe(true);
  expect(facts.published, "the reach reads the pin").toBe(true);
  expect(facts.scopeIsABoard, JSON.stringify(facts)).toBe(true);
  expect(facts.sameAsScopeFor, "the scope is the one the engine publishes").toBe(true);
  expect(facts.sectionReads, "a published board is never read off the element").toBe(0);

  await expect(page.locator("[data-test='studio-board']").getByText("Reached the engine board")).toBeVisible();
  expect(errors.pageErrors, errors.report()).toHaveLength(0);
});
