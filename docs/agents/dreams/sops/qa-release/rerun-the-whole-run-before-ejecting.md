---
question: "At `bin/release prepare`, `accepted` CI is red on one e2e spec that just merged. Do I eject the PR?"
answer: "Not yet. Re-run the WHOLE run (`gh run rerun <id>`, not `--failed`) and eject only if it is red again."
why: "A spec fresh on `accepted` can be flaky; one whole rerun costs minutes, an ejection costs the PR its release."
status: proposed
source: "2026-10-15 · qa-release"
sop: qa-release
step: prepare
topic: [ci, flaky, e2e]
---

# Re-run the whole run before ejecting

## Situation

`accepted` carried a red CI run, and the only failure was one engine e2e spec
(a navbar collapse spec) that had merged hours earlier.

## The pull

Eject the PR that brought the spec in, or re-run only the failed job to save
time.

## What happened

The session re-ran the whole run with `gh run rerun <id>`. A `--failed` rerun
replays one job against a cache and setup the first run left behind; the whole
run answers whether the tree is green. It went green, the release kept the PR,
and a separate task made the spec deterministic so the flake could not recur.
