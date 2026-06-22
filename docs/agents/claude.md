# CLAUDE.md — Claude Code adapter for the McRitchie operating model

Claude Code auto-loads this file; it does **not** auto-load `AGENTS.md` (that is
the Codex convention). So this adapter carries the operating model for Claude
sessions. **Read this whole file before acting.**

## ⛔ STOP — before writing ANY code (feature, bug, or chore — even a "small" one)

If your work will produce a code diff, you are a **Feature agent** and you MUST
run the DevOps cycle. There is **no size exemption** — "it's just a small change"
or "just a registry entry" is exactly when this gets skipped. Do **not** start
editing files until you have:

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

4. Run **`bin/dor-check <task>`** and fix whatever it flags — it refuses an
   under-tested PR.
5. Commit on the feature branch, push, open a PR whose body **leads with the
   task URL**, then `bin/task move <task> submitted`.

Task lifecycle is two workflows meeting at the `submitted` seam — **Build**
(feature agent) `designed → building → submitted` (you own through `submitted`)
and **Deploy** (DevOps) `submitted → reviewed → assembled → shipped` (QA reviews
→ `reviewed` or `bin/task block`s it back; the conductor assembles + ships).
`blocked` = needs attention; `archived` = terminal.
Full spec: `mcritchie-studio/docs/agents/system/devops-cycle-design.md`.

**Never** push to `main`, merge, deploy, or publish gems unless Mr. McRitchie
explicitly assigns you that lane in this session.

If you skipped any of the above and already edited files: stop, create the task
now, move the work into a worktree/branch, and proceed from step 3.

Full SOP + visual: `mcritchie-studio/docs/agents/system/devops-cycle-design.md`
and the admin-gated in-app viewer at `/devops/cycle`.

---

## Full operating model

@AGENTS.md
