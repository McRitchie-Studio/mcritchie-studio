// Signs the seeded admin in once and saves the session for every spec (`use.storageState`
// in playwright.config.js). The hub's ops pages sit behind an admin wall
// (app/controllers/concerns/admin_wall.rb), so a spec that reads the board needs an admin
// session the way a real operator has one. A spec about what a VISITOR sees opts out with
// `test.use({ storageState: VISITOR })` from helpers.js.
//
// Only for the local server this config boots: against an external host (QA or
// production, the @qa-readonly seal) there is no seeded admin and no captured inbox, and
// those runs stay visitors.
const { chromium } = require("@playwright/test");
const { loginWithMagicLink } = require("./helpers");

const ADMIN_STATE = "playwright/.auth/admin.json";
const ADMIN_EMAIL = "alex@test.com";

module.exports = async function globalSetup(config) {
  const { baseURL } = config.projects[0].use;
  const browser = await chromium.launch();
  try {
    const context = await browser.newContext({ baseURL });
    const page = await context.newPage();
    await loginWithMagicLink(page, ADMIN_EMAIL);
    await context.storageState({ path: ADMIN_STATE });
  } finally {
    await browser.close();
  }
};

module.exports.ADMIN_STATE = ADMIN_STATE;
