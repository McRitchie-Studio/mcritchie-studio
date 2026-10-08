// The board's admin login row (agent_login_requests/_pending): an admin sees the
// pending request with its one-time code, and the Approve tap or the code grants
// the admin session, which the requesting harness collects once.
const { test, expect } = require("@playwright/test");

const api = (page, path, body) =>
  page.evaluate(
    async ([p, b]) => {
      const token = document.querySelector('meta[name="e2e-api-token"]')?.content;
      const res = await fetch(p, {
        method: "POST",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: JSON.stringify(b),
      });
      return { status: res.status, body: await res.json().catch(() => ({})) };
    },
    [path, body],
  );

async function askForLogin(page, soul) {
  const harness = `e2e-harness-${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const asked = await api(page, "/api/v1/agent_login_requests", { soul, harness_session_id: harness });
  expect(asked.status, JSON.stringify(asked.body)).toBe(201);
  expect(JSON.stringify(asked.body)).not.toMatch(/"code"/);
  const proof = { collect_key: asked.body.data.collect_key, harness_session_id: harness };
  return { slug: asked.body.data.slug, proof };
}

test("the Approve tap on a pending admin login grants the session, collected once", async ({ page }) => {
  expect((await page.goto("/tasks")).ok()).toBe(true);
  const { slug, proof } = await askForLogin(page, "xan");
  await page.reload();

  const row = page.locator(`#admin-login-${slug}`);
  await expect(row).toBeVisible();
  await expect(row).toContainText("Admin login · Xan");
  await expect(row.locator("[data-test='admin-login-code']")).toHaveText(/^[A-Z2-9]{4}-[A-Z2-9]{4}$/);
  await expect(row.locator("[data-test='task-window-chip']")).toHaveAttribute("data-window-kind", "admin_login");

  const pending = await api(page, `/api/v1/agent_login_requests/${slug}/collect`, proof);
  expect(pending.status).toBe(409);

  await row.locator("[data-test='admin-login-approve']").click();
  await expect(row.locator("[data-test='admin-login-result']")).toHaveText("Granted. The code is spent.");
  await expect(row.locator("[data-test='admin-login-code']")).toHaveCount(0);
  await expect(row.locator("button")).toHaveCount(0);

  const collected = await api(page, `/api/v1/agent_login_requests/${slug}/collect`, proof);
  expect(collected.status).toBe(200);
  expect(collected.body.data.tier).toBe("admin");
  expect(collected.body.data.task_slug).toBeNull();
  expect(collected.body.data.token).toBeTruthy();
  const again = await api(page, `/api/v1/agent_login_requests/${slug}/collect`, proof);
  expect(again.status).toBe(410);

  await page.reload();
  await expect(page.locator(`#admin-login-${slug}`)).toHaveCount(0);
});

test("the code on the row grants with no tap, and Decline grants nothing", async ({ page }) => {
  expect((await page.goto("/deployments")).ok()).toBe(true);
  const coded = await askForLogin(page, "steffon");
  const declined = await askForLogin(page, "xan");
  await page.reload();

  const code = (await page.locator(`#admin-login-${coded.slug} [data-test='admin-login-code']`).textContent()).trim();
  const wrong = await api(page, `/api/v1/agent_login_requests/${coded.slug}/code`, { ...coded.proof, code: "AAAA-AAAA" });
  expect(wrong.status).toBe(403);
  const granted = await api(page, `/api/v1/agent_login_requests/${coded.slug}/code`, { ...coded.proof, code });
  expect(granted.status, JSON.stringify(granted.body)).toBe(200);
  const collected = await api(page, `/api/v1/agent_login_requests/${coded.slug}/collect`, coded.proof);
  expect(collected.status).toBe(200);
  expect(collected.body.data.issued_by).toBe("launch_phrase");

  const row = page.locator(`#admin-login-${declined.slug}`);
  await row.locator("[data-test='admin-login-refuse']").click();
  await expect(row.locator("[data-test='admin-login-result']")).toHaveText("Declined. The code is spent.");
  const refused = await api(page, `/api/v1/agent_login_requests/${declined.slug}/collect`, declined.proof);
  expect(refused.status).toBe(410);
  expect(refused.body.error).toContain("declined by the operator");
});
