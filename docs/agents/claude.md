# CLAUDE.md — Claude Code adapter for the McRitchie operating model

Claude Code auto-loads this file; it does **not** auto-load `AGENTS.md` (that is
the Codex convention). So this adapter carries the operating model for Claude
sessions. **Read this whole file before acting.**

## SOP invocation standard

McRitchie SOPs live in `/Users/alex/projects/AGENTS.md`'s **SOP Invocation
Standard** and the repo docs it points to. SOPs are first-class registered
commands with finite names and stable files. If Mr. McRitchie's prompt names an
SOP or heartbeat act such as `pr-review`, `qa-release`, `production-deploy`,
`archive-shipped`, `deploy-with-task`, `clean-up`, or `full-cycle`, resolve that phrase
through the SOP registry, read the mapped SOP, then execute it. For example, `pr-review` means read
`mcritchie-studio/docs/agents/agents/carl/sops/pr-review.md` first and run that
review-only SOP; do not start with `bin/pr-review --help`, `bin/qa-intake`,
or GitHub PR discovery.

## ⛔ STOP — before writing ANY code (feature, bug, or chore — even a "small" one)

If your work will produce a code diff, you are a **Feature agent** and you MUST
run the DevOps cycle. There is **no size exemption** — "it's just a small change"
or "just a registry entry" is exactly when this gets skipped.

**Use the fast lane — it is the DEFAULT path.** Two wrappers collapse the
bookends below into one command each:

```bash
cd /Users/alex/projects/mcritchie-studio
bin/task begin --title "Three To Five Words" --repo <app> --kind <kind> \
  --shape <shape> --risk <tags> --accept "criterion" --test "[unit] ..."
#   ... build in the worktree it prints ...
bin/ship <task-slug> -m "Commit message"
```

`bin/task begin` runs steps 1-2 (create → worktree → bind → `move building` →
preflight) and prints the worktree path, port, and task URL. `bin/ship`, run
from that worktree, runs steps 4-5 (commit → `bin/fast-check` → push →
**non-draft** PR into `accepted` led by the task URL → record `pr_url` →
`bin/dor-check` → `move submitted` → read-back verify). Re-run either after a
failure and it **resumes**.

Their limits, stated plainly: they change **no gate semantics**; `bin/ship`
stops at `submitted` and never merges or deploys; `bin/ship` has no `--steal`
(take a held task over with `bin/task begin <task-slug> --steal`, then ship);
you still write the tests in step 3; and `bin/ship` is **not** `bin/release
ship`, which is the G4 **production** deploy (`release → main`,
ship-authority only). `begin` passes `--root <worktree>` to
`bin/session-preflight`, and the preflight self-defends that the inspected root
is the task's own desk, so its verdict describes the worktree it just created.

The long form below stays canonical for what the wrappers don't cover
(multi-repo tasks, a bespoke PR body, rerunning one step piecemeal). Either
way, do **not** start editing files until you have:

1. **Created the production task** —
   `cd /Users/alex/projects/mcritchie-studio && bin/task create --title "<feature>"
   --kind feature --shape <shape> --repo <app> --risk <tags>
   --accept "<criterion>" --test "<tier>"`. **Title = 3-5 words** (the create API
   rejects otherwise); the slug derives from it (`/tasks/<slug>`, seeds
   `worktree_slug` + `feat/<slug>`) — pass `--slug` only to override.
   **Each `--accept` bullet = 5-12 words.** Put any verbose detail/reasoning in
   `--agent-context "…"` (free-form, for agent-to-agent communication). Classify
   the **shape** (it selects the tests you must write, per `config/feature_shapes.yml`):
   `ui-only` · `ui+db` · `backend` · `library` · `onchain` · `onchain-vertical`.
2. **Allocated an isolated worktree** — `bin/agent-worktree new <app> <task>` —
   and worked there on an allocated port. Never edit a primary checkout.

While building:

3. Write the **test tiers your shape requires as you go**, unit-first (this is
   how bugs get caught before PR). Record them tier-tagged:
   `bin/task update <task> --checks "[unit] ..." --checks "[integration] ..."`.
   For a **bug**, write the failing regression test FIRST, at the lowest tier
   that reproduces it.

Before handoff:

4. Certify — the task's **G1 Cert** gate: commit, then run `bin/fast-check
   <task>` (the builder default, ~1 min) or `bin/full-suite-check <task>`
   (CI-independent). The pipeline's gates run
   **G1 Cert → G2 Review → G3 Candidate → G4 Ship**; standalone SOPs:
   `mcritchie-studio/docs/agents/modules/gates/`.
5. Push, open a PR **into `accepted`** (base `accepted`, not `release`/`main`)
   whose body **leads with the task URL**; then verdict: run **`bin/dor-check
   <task>`** and fix whatever it flags — it refuses an under-tested PR and its
   verdict closes the gate. Then `bin/task move <task> submitted` **without
   waiting for CI** — pending CI is a loud suggestion (the fast cert is credited
   provisionally); red CI blocks; review's gate-zero holds the authoritative
   CI verdict and bounces a red-CI task back before any reviewer spawns.

Task lifecycle is two workflows meeting at the `submitted` seam — **Build**
(feature agent) `designed → building → submitted` (you own through `submitted`)
and **Deploy** (DevOps) `submitted → reviewed → assembled → shipped`. The code
walks a three-rung branch ladder — **`accepted` → `release` → `main`**: every
repo keeps persistent `accepted` and `release` branches, and feature PRs target
**`accepted`** (not `release`/`main`). On a merge-ready verdict review **merges
the feat PR into `accepted`**, stamps `merged: "accepted"`, then moves the task
`reviewed` (invariant: `reviewed` ⟺ code-on-`accepted`; a merge failure leaves it
`submitted`). Review is still review-only in that it never touches `release`/
`main` and never deploys. Avi's self-healing `qa-release` sweep (`bin/release
prepare`) then **promotes ALL of `accepted` onto `release` via ONE batch PR per
repo** (not N per-task merges), records membership (re-stamping `merged:
"release"`), deploys QA, and flips members `assembled` only on QA-green; Steffon's
`production-deploy` (`bin/release ship`) fast-forwards `release → main` (stamping
`merged: "main"`). `blocked` = needs attention; `archived` = terminal.
Full spec: `mcritchie-studio/docs/agents/system/devops-cycle-design.md`.

**Sizing trio (po/dev/actual).** Avi is the default sizer — he sets `po_size` at
creation (`bin/task create … --po-size small|medium|large|xl`), a forecast, not a
gate (backfill later with `bin/task update --po-size`). The per-task Pokémon
stamps its `dev_size` as it claims the task (`bin/task move <task> building
--dev-size <size>`; optional). At ship, `actual_size` auto-derives from MEASURED
$cost (sum of `cost` across the task's TaskEvents) when blank — powering the sizing
intelligence dashboard.

**Never** push to `main`, merge, deploy, or publish gems unless Mr. McRitchie
explicitly assigns you that lane in this session.

If you skipped any of the above and already edited files: stop, create the task
now, move the work into a worktree/branch, and proceed from step 3.

Full SOP: `mcritchie-studio/docs/agents/system/devops-cycle-design.md`.

---

## Full operating model

@AGENTS.md
