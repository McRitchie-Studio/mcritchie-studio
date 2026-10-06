// Resolve the bare `board/<module>` specifiers the way the browser does.
//
// In the browser, config/importmap.rb pins app/javascript/board under "board", so the
// modules import each other as "board/colors". Node has no import map, so this hook
// maps the same prefix onto the same files.
//
// The repo has no package.json "type", so Node would read a .js file as CommonJS.
// Files under app/javascript and test/javascript are ES modules (that is what the
// browser loads), so this hook says so.
const ROOT = new URL("../../../", import.meta.url);
const BOARD = new URL("app/javascript/board/", ROOT);
const ESM_DIRS = [new URL("app/javascript/", ROOT).href, new URL("test/javascript/", ROOT).href];

export async function resolve(specifier, context, nextResolve) {
  const match = /^board\/([\w/]+)$/.exec(specifier);
  const resolved = match
    ? await nextResolve(new URL(`${match[1]}.js`, BOARD).href, context)
    : await nextResolve(specifier, context);
  if (resolved.url.endsWith(".js") && ESM_DIRS.some((dir) => resolved.url.startsWith(dir))) {
    return { ...resolved, format: "module" };
  }
  return resolved;
}
