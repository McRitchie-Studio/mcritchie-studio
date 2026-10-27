// Loaded with `node --import` by bin/test-js. Installs studio-engine's shared
// importmap hook (node_modules/.studio-engine/node_test/, linked by
// `bin/rails node_tooling:link`, which bin/test-js runs first), so a module
// under test imports "board/colors" or "chat_follow" exactly as the browser does.
//
// THE PREFIXES COME FROM config/importmap.rb, not from a list kept here: every
// `pin_all_from "<dir>", under: "<prefix>"` line becomes one prefix
// (importmap_prefixes.mjs). A second copy of the map would agree with the
// importmap only until someone edits one of them. A bare top-level name
// (`pin "chat_follow"`) resolves to its own file in app/javascript, as before.
import { readFileSync } from "node:fs";
import { importmapPrefixes } from "./importmap_prefixes.mjs";

const ROOT = new URL("../../../", import.meta.url);
const TOOLING = new URL("node_modules/.studio-engine/node_test/register.mjs", ROOT);

const prefixes = importmapPrefixes(readFileSync(new URL("config/importmap.rb", ROOT), "utf8"));
if (Object.keys(prefixes).length === 0) {
  throw new Error("test/javascript/support/register.mjs: config/importmap.rb has no `pin_all_from ..., under:` line to map");
}

let registerImportmapHooks;
try {
  ({ registerImportmapHooks } = await import(TOOLING.href));
} catch (error) {
  if (error.code !== "ERR_MODULE_NOT_FOUND") throw error;
  throw new Error(`studio-engine's Node tooling is not linked at ${TOOLING.pathname}: run \`bin/rails node_tooling:link\` (bin/test-js does)`);
}

registerImportmapHooks({
  root: ROOT,
  prefixes,
  topLevelDir: "app/javascript/",
  esmDirs: ["app/javascript/", "test/javascript/"],
});
