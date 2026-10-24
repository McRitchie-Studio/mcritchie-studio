// Resolve the bare `board/<module>` specifiers the way the browser does.
//
// In the browser, config/importmap.rb pins app/javascript/board under "board", so the
// modules import each other as "board/colors". Node has no import map, so this hook
// maps the same prefix onto the same files. A bare top-level name with a file of its
// own in app/javascript (`import … from "chat_follow"`, pinned by name) maps the same
// way.
//
// The repo has no package.json "type", so Node would read a .js file as CommonJS.
// Files under app/javascript and test/javascript are ES modules (that is what the
// browser loads), so this hook says so.
import { existsSync } from "node:fs";

const ROOT = new URL("../../../", import.meta.url);
const APP_JS = new URL("app/javascript/", ROOT);
const BOARD = new URL("app/javascript/board/", ROOT);
const ESM_DIRS = [new URL("app/javascript/", ROOT).href, new URL("test/javascript/", ROOT).href];

export async function resolve(specifier, context, nextResolve) {
  const match = /^board\/([\w/]+)$/.exec(specifier);
  const topLevel = /^[a-z_]+$/.test(specifier) && existsSync(new URL(`${specifier}.js`, APP_JS)) ? new URL(`${specifier}.js`, APP_JS).href : null;
  let resolved;
  if (match) resolved = await nextResolve(new URL(`${match[1]}.js`, BOARD).href, context);
  else if (topLevel) resolved = await nextResolve(topLevel, context);
  else resolved = await nextResolve(specifier, context);
  if (resolved.url.endsWith(".js") && ESM_DIRS.some((dir) => resolved.url.startsWith(dir))) {
    return { ...resolved, format: "module" };
  }
  return resolved;
}
