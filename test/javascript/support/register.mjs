// Loaded with `node --import` by bin/test-js; installs importmap_hooks.mjs.
import { register } from "node:module";

register("./importmap_hooks.mjs", import.meta.url);
