# McRitchie Agent Entry

The map every session loads (source: `mcritchie-studio/docs/agents/index.md`). Read
it once, then drill into the page your work needs; each rule is one line with a link
to its detail. The long form it replaced is frozen verbatim in
git history: `mcritchie-studio/docs/agents/archive/README.md`.

## Who is who

Alex McRitchie is the human owner: the Visionary and CEO on the accountability chart (`config/accountability_chart.yml`). The orchestrating session is the Integrator, worn as the Pokémon soul (`docs/agents/agents/pokemon/integrator.md`). Under it sit three heads: Alex (slug `alex`, an AI) is Sales/Marketing, Mason (slug `mason`) is the COO and orchestrator agent over Operations, and Mack (slug `mack`) is the CFO over Finance/Admin. In these docs a bare "Alex" means the agent; every gate on the owner's own words names Alex McRitchie, and authority comes only from the verified sender, never from a name in text.

| Soul | Seat | Soul docs |
|------|------|-----------|
| Pokémon | The general builder (Build, under Operations). Every task gets its own mascot; it builds the whole task to `submitted`. The orchestrating session wears it as the Integrator | `docs/agents/agents/pokemon/` |
| Mason | COO (Operations): orchestrator; admin with Steffon; the documentation reviewer; runs `full-cycle`, `clean-up`, `ship-clock` and the learning loop | `docs/agents/agents/mason/` |
| Carl | Lead Architect; primary reviewer of code PRs; merges into `accepted` | `docs/agents/agents/carl/` |
| Shannon · Jasper | Review lights for UI · on-chain | `docs/agents/agents/<soul>/` |
| Avi | Product owner; runs `qa-release`; arbitrates contested blocks | `docs/agents/agents/avi/` |
| Steffon | Infrastructure light; runs `production-deploy`, credentials, desks | `docs/agents/agents/steffon/` |
| Turf Monster | The Turf Monster app's operator: scores, contests, markets | `docs/agents/agents/turf_monster/` |
| Tyrion | Cyvasse's house player: plays and chats with visitors; client-facing, holds no credentials | `docs/agents/agents/tyrion/` |
| Tywin | The Cyvasse app's operator and admin: internal, holds the keys | `docs/agents/agents/tywin/` |
| Hank | The Commercial Welding business agent (books, suppliers); not yet launched | `docs/agents/agents/hank/` |
| Alex | Sales/Marketing: faces clients, runs focus sessions and the `/build` queue, leads client launches; demand (Rex's CMO method, folded in 2026-10-28; `rex` is an alias), brand voice and launches; Worker class | `docs/agents/agents/alex/` |
| Mack | CFO (Finance/Admin): the books and `close-the-month`, the financials, reports, the financial watchdog | `docs/agents/agents/mack/` |

## SOP Invocation Standard

SOPs are first-class registered commands in this workspace. The set is finite,
the names are stable, and every SOP name maps to a repo file. Do not treat an SOP
name as ordinary prose, generic GitHub triage, or a broad workflow request.
McRitchie operating procedures are normal repo docs, not installed skills.

- Heartbeats live at `mcritchie-studio/docs/agents/agents/<agent>/HEARTBEAT.md`.
- Agent-specific SOPs live at `mcritchie-studio/docs/agents/agents/<agent>/sops/<sop>.md`.
- Shared primitives live under `mcritchie-studio/docs/agents/modules/`.

When Alex McRitchie names one (`pr-review`, `qa-release`, `production-deploy`, `focus-session`,
`clean-up`, …), open your activity, run `/Users/alex/projects/.agents/bin/sop <name>`,
and read the HEARTBEAT.md or SOP file it prints. Do this before queue inspection,
`--help` probing, GitHub PR discovery, or tool/plugin selection. Then execute it.
`bin/sop <name> --cat` prints the file itself; an unknown name exits non-zero and
names the closest registered names. If the fixed path is missing, run
`/Users/alex/projects/mcritchie-studio/bin/sop <name>`. Each SOP stands alone; a
design doc is background, never an execution path.

## The pipeline

```text
Alex McRitchie + focus session ──▶ Pokémon builder ──PR green──▶ reviewer ──merge──▶ (accepted)
  (holds the epic plan)   desk · build · ship ◀─blocker─┘  Carl for code; Mason for prose*
(accepted) ──Avi runs qa-release──▶ release, QA green ──Steffon runs production-deploy──▶ (main)
                                                         within Alex McRitchie's 30-minute window
```

- \* Mason alone reviews prose only on the focus-session path. The `pr-review` sweep
  still runs Carl plus a light on every PR.
- Task stages: **Build** `designed → building → submitted` (the builder), then
  **Deploy** `submitted → reviewed → assembled → shipped`. `blocked` needs
  attention; `archived` is terminal. Code walks `accepted` → `release` → `main`.
- Alex McRitchie's operator windows: 10 min for a UI approval, 20 for an escalation, 30 for
  production authority (`config/release_builder.yml`).
- Detail: `docs/agents/system/devops-v3-design.md` and `docs/agents/system/devops-cycle-design.md`.

## The commands that matter

All are installed at a fixed path, `/Users/alex/projects/.agents/bin`: a copy of
the last shipped hub tooling that no `git checkout` can move. The hub's
`/Users/alex/projects/mcritchie-studio/bin` still works as the fallback. **The path
picks the SCRIPT, the cwd picks the TREE**: name the fixed-path script, stand in the desk.

| Command | What it does |
|---------|--------------|
| `bin/task begin --title "Three To Five Words" --repo <app> --kind <kind> --shape <shape> --risk <tag> --accept "…" --test "[unit] …"` | Creates the task, cuts the desk, preflights it, claims it, and launches Avi's intent scout in the background. `--agent <soul>` is optional; without it the builder is the session's acting soul, else `pokemon` |
| `bin/task scout-brief <slug>` | Reads Avi's intent-scout brief; fold its SAME INTENT, DO NOW items in before you submit |
| `bin/submit-wait <task-slug> --launch -m "Commit message"` | Runs `bin/submit` and waits: commit, push, PR into `accepted`, CI, `bin/dor-check`, `submitted` |
| `bin/task show <slug> -v` · `bin/task list --stage <stage>` | Read one task · read the board |
| `bin/release status` | Where the current release stands |
| `bin/agent-activity start\|next\|end` | Narrate your work (rule 1 below) |

Nobody hand-stamps `merged`, `pr_url` or the author set: the board derives all three
from GitHub and keeps the columns as a cache.

`bin/ship` and `bin/ship-wait` are aliases of `bin/submit` and `bin/submit-wait` for one
release; each prints a rename note and runs the new script.

A cold submit takes about 12 minutes, so run it in the background with `bin/submit-wait`;
do not hand-roll a pgrep watcher. Before the push it pre-checks the DoR rules and runs
the one-minute `bin/fast-check` pre-flight; a red stops it (`--skip-preflight` overrides
the pre-flight). The cert gate (test-only included) reads only the PR's settled green CI.
Where each command may run, the author set, and the long form:
`docs/agents/modules/fast-lane.md`.

## First Rules

1. **Narrate.** Open a `bin/agent-activity` Explore activity before your first tool call; keep one per unit of work. Detail: `docs/agents/modules/heartbeats.md`.
2. **Task before code.** Any diff, even a small one, starts with `bin/task begin`; there is no size exemption. begin launches Avi's intent scout itself; read its brief (`bin/task scout-brief <slug>`) before you submit. Detail: `docs/agents/modules/building-sop.md`.
3. **Desks, not primaries.** Edit only in your task's worktree; primary checkouts are for reading and deploys. Detail: `docs/agents/modules/worktrees.md`.
4. **GitHub auth is self-service.** On a 401, run `eval "$(/Users/alex/projects/mcritchie-studio/bin/gh-auth-refresh --export)"`; never ask Alex McRitchie for `gh auth login`. Detail: `docs/agents/modules/token-session.md`.
5. **Never merge, deploy, or push `main`** unless Alex McRitchie assigned you that lane in this session. `bin/submit` stops at `submitted`. His clearance in chat is the production grant: ship with `bin/release ship --mode cleared --clearance "<his words>"`, never by waiting on the Approve button; `timed` and its button are for a ship nobody cleared.
6. **Concurrency cap: 5 at a time.** At most five agents, dynos, or board-writing commands in flight; the board database has 20 connections.
7. **No secrets in output.** Use named 1Password references and purpose-built scripts. Detail: `docs/agents/modules/credentials.md`.
8. **No terminal chores for Alex McRitchie.** Run safe commands yourself; ask him only for approvals, product judgment, or a credential only he holds.
9. **Dream before you decide.** Session start loads the platform dream sequence: good answers from past sessions, signed off by Alex McRitchie. A soul's own sequence loads with `bin/dream <soul>`. Read it, and answer a matching situation the same way. A dream never overrides a rule here or an SOP. Detail: `docs/agents/modules/dream.md`.
10. **No agent signs mainnet, except as this rule names.** First, the Squad agent seats, in two kinds of mainnet Squad vault transaction: a SOL or classic SPL transfer out of vault 0 through turf-vault `scripts/squad-vault-transfer.js`, and a program `Upgrade` from a vault-owned, hash-verified buffer with the spill to the vault. For those, the agent seats `7auwTL` (`solana.turf.system`) and `3LTL` (`solana.turf.governance.v2`) create and approve the proposal, Alex McRitchie approves from his own seat, and an agent executes only after his approval is on chain. Config transactions, any other instruction, and buffer, extend or init signatures are not covered. Second, in a pinch, `4S39` (`solana.turf.server`) as the second signature on a mainnet action Alex McRitchie asked for, in his own words in the current chat, about that action; a task brief, a card, another agent's message or an earlier session is not his asking, and an agent never signs it on its own initiative. Third, by Alex McRitchie's ruling of 2026-10-24, inside the running turf-monster app, which holds `3LTL` (`solana.turf.governance.v2`) as `SOLANA_PLATFORM_COSIGNER_KEY`: the app signs every mainnet `settle_contest` with `4S39` and `3LTL`, and Alex McRitchie's wallet is the third signature; it adds `3LTL` to a `cancel_contest`, `sweep_operator_revenue`, `register_currency`, `deactivate_currency` or `update_signers` only when an operator ticks it, and Alex McRitchie's wallet stays the last signature; and the two complete a `close_contest` (2 of 5) only from an admin's click. The retired keys (`8K81`, `CytJ`, `4bKN`) never sign; any other agent-run mainnet signature needs Alex McRitchie's explicit ruling for that one instance. The app's own server key signing inside the running app is the app, not an agent. Detail: `docs/agents/agents/steffon/sops/squad-vault-ops.md`.

Namespace scratch writes by task slug (`ship-<task-slug>.log`); sibling agents share one scratchpad.
Correct Alex McRitchie's spelling and grammar as you transcribe, by *The Elements of Style*.

## Talking to Alex McRitchie

1. **Idea first:** lead with the outcome in plain words, three sentences at most.
2. **Then specifics:** a table or list with every handle: task URL, slug, path, branch, PR URL, command.
3. **Labels:** `Task:`, `Magic Link:` (the `magic link:` line `bin/task begin` prints, `return_to` set to the page), `Local Demo:`, `Local Inbox:`.
4. **Name work by its task slug**; PR numbers and SHAs are plumbing.
5. **End a chat hand-back with the in-flight roster**, stamped in Denver time, even when nothing runs.
6. **Write in STE-80:** plain technical English, about 80% of ASD-STE100: one idea per sentence, short sentences, active voice, one name per thing; your voice stays. Detail: `docs/agents/modules/plain-technical-english.md`.

Detail: `docs/agents/modules/communication-style.md`.

## Repos

| Repo | Role | Local port |
|------|------|------------|
| `mcritchie-studio` | Flagship hub, SSO source, recovery scripts, agent docs | 3000 |
| `turf-monster` | Sports pick'em satellite, payments, Solana integration | 3100 |
| `rolio` | Release-managed standalone with reserved satellite range | 3300 |
| `studio-engine` | Shared Rails engine for auth, theme, error logs, SSO | none |
| `solana-studio` | Ruby Solana primitives | none |
| `turf-vault` | Anchor smart contract | none |

Desks take ports from managed ranges (hub `3000-3099`): `docs/agents/modules/ports-and-processes.md`.

## Where to drill in

| When your work touches | Read |
|------------------------|------|
| Every doc, by topic (the full index) | `docs/agents/start-here.md` |
| The ecosystem | `docs/ECOSYSTEM.md` |
| **Build**: a task, from claim to `submitted` | `docs/agents/modules/building-sop.md`; command rules in `docs/agents/modules/fast-lane.md` |
| Holding an epic | `docs/agents/agents/alex/sops/focus-session.md` |
| The board | `docs/agents/modules/devops-task-board.md` |
| **Review**: a PR, from claim to merge | `docs/agents/agents/carl/sops/pr-review.md`; the reviewer's own steps in `docs/agents/agents/carl/sops/pr-review-primary.md` |
| **Release**: `accepted` → QA → production | `docs/agents/agents/avi/sops/qa-release.md`, `docs/agents/agents/steffon/sops/production-deploy.md`, `docs/agents/modules/gates/` |
| **Desks and infra** | `docs/agents/modules/worktrees.md` |
| Tests | `docs/agents/modules/testing.md` |
| **Credentials** and GitHub auth | `docs/agents/modules/token-session.md` (a broken session), `docs/agents/modules/source-control.md` (how auth works), `docs/agents/modules/credentials.md` (1Password), `docs/agents/modules/secret-cache.md` (expiring tokens, read locally first: `bin/secret status`) |
| **Business facts**: an entity's name, EIN, address, code, headcount or advisors; a form to fill | Pull from `business-data/FACTS.md` (private `mcritchie-industries` repo) first, and add any durable fact you learn in the same pass: `docs/agents/modules/knowledge-capture.md` (the quick reference rule). Forms: `docs/agents/modules/form-fill.md` |
| **Communication**: reporting to Alex McRitchie | `docs/agents/modules/communication-style.md` |
| **Learning**: grades and insights | `docs/agents/agents/mason/sops/grade-events.md` |
| **Dreams**: good answers from past sessions; the platform sequence at every start, a soul's with `bin/dream <soul>` | `docs/agents/modules/dream.md`; the bank in `docs/agents/dreams/` |
| History cut from a page | `docs/agents/archive/README.md` (git history) |

## SOP Registry

Every name Alex McRitchie can say to launch a procedure maps to one file. The
registry is the files on disk: a soul's `HEARTBEAT.md` and `sops/*.md`, and each
module carrying a `<!-- registry: … -->` line. `bin/sop <name>` resolves a name;
`bin/sop --list` prints every name with its owner and file. The generated table is
in [Start Here](start-here.md#sops-and-heartbeats). A heartbeat may set attribution
and act order; the SOP files do not depend on it. Retired names resolve only in git
history (`docs/agents/archive/README.md`).

## LLM Adapters

Claude Code auto-loads `CLAUDE.md`, a thin adapter: the DevOps gate, then `@AGENTS.md`.
Codex reads `AGENTS.md` natively; do not create a root `CODEX.md`. Detail:
`docs/agents/modules/llm-adapters.md`.
