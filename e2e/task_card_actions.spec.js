const { test, expect } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

async function createTask(page, token, attrs) {
  const res = await page.request.post("/api/v1/tasks", {
    headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    data: attrs,
  });
  expect(res.ok(), await res.text()).toBeTruthy();
}

// WHY THIS SPEC RECORDS `data-exit-action` INSTEAD OF ASSERTING ON IT.
//
// The property under test is real and worth keeping: archive and delete must use
// DISTINCT exits. `data-exit-action` is the load-bearing carrier of that
// distinction — the board branches on it (`_board.html.erb`
// installArchiveExitStream re-parents only when it reads 'archive', and the
// engine's animateCardExit picks its keyframes from it), so it is the right
// thing to assert on. What was wrong was HOW.
//
// The original spec clicked, then polled for the attribute:
//
//     await archiveCard.locator("[data-test='task-card-archive']").click();
//     await expect(archiveCard).toHaveAttribute("data-exit-action", "archive");
//
// `data-exit-action` exists only WHILE the exit is running, on a card the same
// click is removing, so that assertion resolves on timing, not on behaviour. And
// the window it polls is not merely short — it is NON-DETERMINISTIC, because two
// independent exit paths race for the same card:
//
//   1. the direct path — archiveTask() stamps the attribute, awaits the exit
//      animation, PATCHes, re-parents, then resetCardExit() strips it;
//   2. the broadcast path — that same PATCH fires a Turbo `remove` stream, and
//      the turbo:before-stream-render handler stamps, animates and strips AGAIN.
//
// resetCardExit() calls `.cancel()` on the card's animations, so whichever path
// lands first collapses the other one's `anim.finished` early — and the attribute
// dies with it. MEASURED on an idle machine with a MutationObserver: the archive
// marker was readable for 27.9ms and 29.5ms on two runs, and the delete marker for
// 18.2ms and 20.9ms — against exit animations of 500ms and 420ms that the
// assertion was implicitly relying on. The window is a fetch round-trip, not an
// animation.
//
// It is also not a STABLE 30ms, which is the part that made this a flake rather
// than a permanent failure: whether the poll lands inside it depends on machine
// load. Reproduced here — the pre-change spec, --repeat-each=25 under 24 busy
// processes, failed 1 run in 25 at the `delete` assertion. In CI it cost three
// release attempts (RED on 84a5c3b, GREEN on a same-tree re-run of 84a5c3b, RED
// on 4957746) before it was fixed here.
//
// Nothing DURABLE carries the exit kind, so there is no post-hoc state to assert
// instead — archive leaves the card re-parented into #dropzone-archived with
// `data-exit-action` DELETED, and delete leaves no card at all. The durable
// difference that does survive (moved vs gone, PATCH vs DELETE) is asserted
// below, but on its own it would pass under a single shared exit and lose the
// point of the test.
//
// So the fix observes the attribute AT THE MOMENT IT IS SET rather than polling
// for it afterwards. A MutationObserver armed BEFORE the click records every
// value the attribute ever takes (see recordExitActions for why it reads
// `oldValue` and not just the live attribute). MutationObserver records are
// queued synchronously at mutation time, so a value is captured even when the
// node is removed microseconds later. The recording cannot be lost to a slow
// poll, a loaded runner, or either path winning the race — it is race-free by
// construction, not by a widened timeout.
//
// DO NOT "simplify" this back to a toHaveAttribute() on the card, and do not
// weaken it to "the card went away" — the first is the flake and the second
// passes under a single shared exit.

// Arm the recorder BEFORE the click that triggers the exit. Records every
// distinct value `data-exit-action` takes on this card, in order.
//
// It reads `oldValue` and not just the live attribute, and that is the detail
// that makes this race-free rather than merely lucky. MutationObserver records
// are QUEUED synchronously but DELIVERED as a microtask, so by the time the
// callback runs the attribute may already have moved on — read only the live
// value and a set-then-delete inside a single task records NOTHING. Today's code
// awaits a fetch between the stamp and the strip so a checkpoint always falls
// between them, but that is a property of the current implementation, not of the
// observer. `attributeOldValue` closes it for good: every value the attribute
// ever held shows up either as some record's oldValue or as the live value.
async function recordExitActions(page, slug) {
  await page.evaluate((s) => {
    window.__exitActions = window.__exitActions || {};
    window.__exitObservers = window.__exitObservers || {};
    window.__exitActions[s] = [];
    const drain = (records) => {
      const seen = window.__exitActions[s];
      const add = (value) => { if (value && !seen.includes(value)) seen.push(value); };
      for (const record of records) {
        add(record.oldValue);
        add(record.target.getAttribute("data-exit-action"));
      }
    };
    const observer = new MutationObserver(drain);
    observer.observe(document.getElementById(`card-${s}`), {
      attributes: true,
      attributeOldValue: true,
      attributeFilter: ["data-exit-action"],
    });
    window.__exitObservers[s] = { observer, drain };
  }, slug);
}

// Read the recording back, draining anything still queued first so the result
// never depends on microtask delivery having already happened.
async function exitActionsFor(page, slug) {
  return page.evaluate((s) => {
    const entry = window.__exitObservers[s];
    entry.drain(entry.observer.takeRecords());
    return window.__exitActions[s];
  }, slug);
}

test("task card archive and delete buttons persist and use distinct exits", async ({ page }) => {
  await loginWithMagicLink(page, "alex@test.com");
  await page.goto("/tasks");

  const token = await page.getAttribute("meta[name='e2e-api-token']", "content");
  const suffix = Date.now();
  const archiveSlug = `e2e-archive-action-${suffix}`;
  const deleteSlug = `e2e-delete-action-${suffix}`;

  await createTask(page, token, {
    slug: archiveSlug,
    title: "E2E archive action card",
    stage: "building",
    priority: 1,
    agent_slug: "alex",
  });
  await createTask(page, token, {
    slug: deleteSlug,
    title: "E2E delete action card",
    stage: "building",
    priority: 1,
    agent_slug: "alex",
  });

  await page.reload();

  // --- archive: the card SURVIVES, re-parented into the archived column -------
  const archiveCard = page.locator(`#card-${archiveSlug}`);
  await expect(archiveCard).toBeVisible();
  await expect(archiveCard.locator("[data-test='task-card-archive']")).toBeVisible();
  await recordExitActions(page, archiveSlug);
  const archiveRespPromise = page.waitForResponse((response) =>
    response.url().includes(`/tasks/${archiveSlug}.json`) && response.request().method() === "PATCH"
  );
  await archiveCard.locator("[data-test='task-card-archive']").click();
  const archiveResp = await archiveRespPromise;
  expect(archiveResp.ok(), await archiveResp.text()).toBeTruthy();
  await expect(page.locator(`#dropzone-archived #card-${archiveSlug}`)).toHaveAttribute("data-stage", "archived");
  await expect(archiveCard).toBeHidden();

  // --- delete: the card is REMOVED outright ----------------------------------
  const deleteCard = page.locator(`#card-${deleteSlug}`);
  await expect(deleteCard).toBeVisible();
  await expect(deleteCard.locator("[data-test='task-card-delete']")).toBeVisible();
  await recordExitActions(page, deleteSlug);
  page.once("dialog", (dialog) => dialog.accept());
  const deleteRespPromise = page.waitForResponse((response) =>
    response.url().includes(`/tasks/${deleteSlug}.json`) && response.request().method() === "DELETE"
  );
  await deleteCard.locator("[data-test='task-card-delete']").click();
  const deleteResp = await deleteRespPromise;
  expect(deleteResp.status()).toBe(204);
  await expect(deleteCard).toHaveCount(0);

  // --- the exits were DISTINCT ------------------------------------------------
  // Read after both exits have fully settled. Each card must have been stamped
  // with its OWN exit kind and never the other's: collapse archive and delete
  // onto one shared exit action and these three assertions go red.
  const archiveExits = await exitActionsFor(page, archiveSlug);
  const deleteExits = await exitActionsFor(page, deleteSlug);
  expect(archiveExits, `archive card exit actions: ${JSON.stringify(archiveExits)}`).toEqual(["archive"]);
  expect(deleteExits, `delete card exit actions: ${JSON.stringify(deleteExits)}`).toEqual(["delete"]);
  expect(archiveExits).not.toEqual(deleteExits);
});
