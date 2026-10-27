// The importmap's directory prefixes, read from config/importmap.rb source: each
// `pin_all_from "<dir>", under: "<prefix>"` line maps "<prefix>/x" onto "<dir>/x.js".
// register.mjs hands the result to studio-engine's shared node:test hook.
export function importmapPrefixes(source) {
  const prefixes = {};
  const line = /^\s*pin_all_from\s+["']([^"']+)["']\s*,\s*under:\s*["']([^"']+)["']/gm;
  for (const [, dir, prefix] of source.matchAll(line)) {
    prefixes[prefix] = dir.endsWith("/") ? dir : `${dir}/`;
  }
  return prefixes;
}
