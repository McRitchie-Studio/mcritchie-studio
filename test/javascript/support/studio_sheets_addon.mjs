// Loads the Studio Sheets add-on (addons/studio-sheets/src) into a fresh V8
// context, the way Apps Script runs it: every file's top-level declarations share
// one global scope. `globals` supplies the Apps Script services (SpreadsheetApp,
// ScriptApp, Session, Utilities) or fakes of them; the returned context exposes
// every top-level function and var.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

export const ADDON_DIR = fileURLToPath(new URL("../../../addons/studio-sheets/", import.meta.url));

export function loadAddon(globals = {}, files = ["Logic.js", "Studio.js"]) {
  const context = vm.createContext({ ...globals });
  for (const file of files) {
    vm.runInContext(readFileSync(`${ADDON_DIR}src/${file}`, "utf8"), context, { filename: file });
  }
  return context;
}
