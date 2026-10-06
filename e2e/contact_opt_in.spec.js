// [e2e] /contact — the SMS opt-in page, the way a visitor walks it.
//
// What only a browser can prove: no consent box starts ticked, ticking "No"
// clears both "Yes" boxes (and a "Yes" clears "No"), the mobile number becomes
// required only once a "Yes" is ticked, the bot trap is out of a person's
// reach, and a consenting visitor lands on the confirmation with the
// operator's notice sent.
const { test, expect } = require("@playwright/test");
const { VISITOR } = require("./helpers");

// What a visitor sees: signed out, not the suite's default admin session.
test.use({ storageState: VISITOR });

test("a visitor opts in to texts on the contact page and sees it confirmed", async ({ page }) => {
  await page.goto("/contact");
  const loadedAt = Date.now();

  const care = page.locator("[data-test='consent-care']");
  const marketing = page.locator("[data-test='consent-marketing']");
  const declined = page.locator("[data-test='consent-declined']");
  const phone = page.getByLabel("Mobile phone number");

  // Nothing is pre-ticked, and the disclosure is on the page under the form.
  await expect(care).not.toBeChecked();
  await expect(marketing).not.toBeChecked();
  await expect(declined).not.toBeChecked();
  await expect(phone).not.toHaveAttribute("required", /.*/);
  const disclosure = page.locator("[data-test='sms-disclosure']");
  await expect(disclosure).toContainText("Reply 'STOP' to unsubscribe at any time. Reply 'HELP' for assistance or more information.");
  await expect(disclosure.getByRole("link", { name: "https://mcritchie.studio/privacy" })).toHaveAttribute("href", "/privacy");

  // "No" and "Yes" exclude each other.
  await care.check();
  await marketing.check();
  await expect(phone).toHaveAttribute("required", /.*/);
  await declined.check();
  await expect(care).not.toBeChecked();
  await expect(marketing).not.toBeChecked();
  await expect(phone).not.toHaveAttribute("required", /.*/);
  await care.check();
  await expect(declined).not.toBeChecked();

  // The bot trap is on the page but no person meets it: off-screen, hidden
  // from assistive tech, not a tab stop, and named so no autofill fills it.
  const trap = page.locator("[data-test='contact-honeypot']");
  await expect(trap).toHaveCount(1);
  await expect(trap).toHaveAttribute("name", "contact_submission[leave_blank]");
  await expect(trap).toHaveAttribute("tabindex", "-1");
  await expect(trap).not.toBeInViewport();
  await expect(page.getByRole("textbox", { name: "Leave this field empty" })).toHaveCount(0);
  await expect(trap).toHaveValue("");

  // The page's script wrote the browser proof (the signed render time,
  // reversed); a bot that skips the script leaves it blank.
  const proof = page.locator("[data-test='contact-proof']");
  const signed = await proof.getAttribute("data-proof");
  await expect(proof).toHaveValue(signed.split("").reverse().join(""));

  const email = `opt-in-${Date.now()}@example.test`;
  await page.getByLabel("Name", { exact: true }).fill("Jordan Lee");
  await page.getByLabel("Email", { exact: true }).fill(email);
  await phone.fill("(303) 555-0142");
  await page.getByLabel("Message", { exact: true }).fill("Please text me about my project.");
  // A person takes longer than the minimum fill time; a script does not.
  const minMs = Number(await proof.getAttribute("data-min-seconds")) * 1000 + 500;
  await page.waitForTimeout(Math.max(0, minMs - (Date.now() - loadedAt)));
  await page.locator("[data-test='contact-submit']").click();

  await expect(page.locator("[data-test='contact-sent']")).toContainText("your message is on its way");
  await expect(page.locator("[data-test='contact-sent-sms']")).toContainText("Reply STOP to cancel.");
  expect(new URL(page.url()).pathname).toBe("/contact");
  // The form is fresh again: nothing carried over as ticked.
  await expect(care).not.toBeChecked();

  // The operator's notice is in the outbox.
  let notice;
  for (let attempt = 0; attempt < 20 && !notice; attempt += 1) {
    const inbox = await page.request.get("/_studio/local_emails.json").then((r) => r.json());
    notice = inbox.deliveries.find((d) => d.to === "alex@mcritchie.studio" && d.email_key === "ContactMailer#submission");
    if (!notice) await page.waitForTimeout(250);
  }
  expect(notice, "the operator notice was sent").toBeTruthy();
});
