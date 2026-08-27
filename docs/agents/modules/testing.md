# Testing

Use the smallest verification that proves the change, then broaden when the
touched surface has shared behavior or money/security risk. Do not treat
"Playwright shard failed" as one undifferentiated verdict; classify which lane
failed and whether that lane blocks the current stage.

## Task Test Metadata

Tasks separate planned checks from completed checks:

- `devops.test_plan` is the expected verification plan captured before or
  during implementation.
- `devops.checks_run` is the actual verification evidence recorded during PR,
  QA, and release handoff.

Feature agents fill `test_plan` before coding and update `checks_run` before
moving to `submitted`. Avi and release conductors append QA and production
checks to `checks_run` as each stage completes.

## Test Lanes

| Lane | Target | Mutates data | Blocks merge | Gate | When to run |
|---|---|---:|---:|---|---|
| PR review gate | Local repo or CI | Usually no | Yes | G1 Cert (builder cert + dor verdict) · G2 Review (the review wave) | Every PR with code changes; includes lint, security scans, Rails tests, and focused browser checks for touched UI |
| E2E (Playwright) | CI, sharded 3× (own server + PG per shard) | Test DB only | **Yes** | G2 Review (the authoritative CI verdict) | Every PR and every push to `main`/`release` — the `playwright` job in `ci.yml`. Collects the **`e2e` tier** (shapes `ui+db`, `onchain-vertical`) |
| E2E executed-set | CI, reads each shard's JSON receipt | No | **Yes** | G2 Review | The `e2e_executed_set` job, after the shards. Asserts the lane **ran the `executed` set `config/e2e_lane.yml` declares** — the one thing the `playwright` job cannot verify about itself |
| Rails executed-set | CI, reads each shard's JSON receipt | No | **Yes** | G2 Review | The `rails_executed_set` job, after the four `rails` shards (`bin/rails-executed-set-check`). Asserts every committed file `config/rails_lane.yml` owns **ran at least one test, in exactly one shard**. Each receipt also names **the commit its shard ran**, and the gate refuses to audit across commits — see below |
| Local proof | Worktree URL | Local DB only | Usually yes | G1 Cert (builder evidence) | UI, auth, task, contest, navigation, email capture, Redis, or worker changes |
| QA acceptance | Stable QA URL | QA/devnet only when named | No; blocks production promotion | G3 Candidate | After every QA deploy; runs task acceptance criteria against the merged result |
| Production smoke | Production URL | No by default | N/A | G4 Ship (the seal — non-blocking) | After approved production deploy; verifies health and key read-only routes |
| Nightly/deep | Dedicated local/QA/devnet target | Often yes | No | — | devnet/on-chain and longer seeded workflows. **No browser matrix exists** — Playwright is Chromium-only in every repo — and the ecosystem's only scheduled workflow (turf-monster's `devnet-nightly.yml`) is disabled and has never run. Treat this row as a *target shape*, not as coverage you have |
| Quarantine | Any | Varies | No until fixed | — | Known flaky or unrelated checks that still matter but should produce follow-up tasks instead of blocking unrelated PRs |

**A receipt names the COMMIT its shard ran, and the Rails executed-set gate will not
audit across two of them.** The gate re-derives the expected file set from a tree it
checks out ITSELF, while the receipts were written by shards that checked out theirs. In
the hub's own CI both are the same `github.sha` and the question never arises. In a
CONSUMER lane — studio-engine running the hub's suite against an engine commit — each job
resolves a BRANCH NAME independently, minutes apart, and a branch is a moving target.

Measured on 2026-08-21 (engine run `32495361932`): the shards checked out hub `accepted`
at 15:02:17 and the gate at 15:06:17; hub PR #979 merged `f9a440e5` at 15:04:07, adding
two test files. The gate audited 482 files against receipts written over 480 and reported
the two newcomers as committed files that **"executed NOTHING"** — arithmetically correct,
completely misleading, and indistinguishable from the real coverage hole the gate exists
to catch. They had run green in the hub's own lane minutes earlier; they simply had not
existed when the shards started.

So `"commit"` is part of the receipt, and:

- receipts that **disagree with each other** are RED — shards straddling a merge produce a
  union no single tree ever contained, and no verdict over it means anything, green included;
- receipts that disagree with **the gate's tree** are RED as a **checkout race**, naming both
  SHAs, with the file-level findings **withheld** rather than printed under the wrong
  headline;
- a receipt that names **no** commit is SILENT, not dissenting, and is audited exactly as
  strictly as before — silence never buys an exemption.

The gate stays RED in every one of those cases on purpose. Commit identity is a
precondition for the arithmetic, never an excuse from it: when the commits agree, a file
that did not run is still the central RED this gate is for. The race itself is fixed where
it happens — by pinning every job in a run to one consumer commit — not by relaxing the
gate.

**The Playwright suite BLOCKS MERGE as of 2026-07-13 (PR #543).** It is a PR-gate
lane, not a nightly one: a red spec makes CI red and the PR does not merge. Before
that date NO lane ran it while `config/feature_shapes.yml` demanded the `e2e` tier of
every `ui+db` change — the tier was "collected" by a builder typing `[e2e] …` into
`checks_run` and `bin/dor-check` crediting the tag. It went unrun long enough for
**18 of its specs to rot** (18 of the 69 committed at the time); those carry `@quarantine`, CI excludes them with
`--grep-invert @quarantine`, and their count is ratcheted — the ceiling is
`quarantined` in `config/e2e_lane.yml`, it may only fall, and
`test/lib/e2e_quarantine_ratchet_test.rb` enforces that. Do not read the green
`playwright` check as "the whole e2e suite passes" until that ceiling reaches 0.

**Repair lands cluster by cluster, so look the current ticket up on the board rather
than trusting a slug pinned here.** `/tasks/repair-quarantined-e2e-clusters` took the
first three (2026-08-18); the rest are still tagged. This paragraph cited
`/tasks/repair-rotted-e2e-specs` as the live ticket long after that task was archived
with all 18 specs still tagged — the "archived task the docs cite as live" trap
catalogued in `docs/agents/agents/alex/sops/clean-up.md`.

**"May only fall" is enforced, and note WHERE the baseline comes from** — the ratchet
compares the ceiling against its value on **`origin/release`**, not against the copy in
your branch. The first version compared it to the contract file the author was editing,
which is a **pin, not a ratchet**: review tagged a 19th spec, bumped the contract 18 → 19,
and *every guard in the repo went green — including the runtime receipt*, because 50 == 50
is just as green as 51 == 51. The hole grew with the whole build green. A guard whose
reference value moves with the thing it restrains restrains nothing; the fix, as everywhere
else in this lane, was to read a number the author's own diff cannot reach. (The `test` job
therefore checks out with `fetch-depth: 0`, and the ratchet fails **closed** — red, saying
why — if it cannot resolve the baseline.)

**What stops a spec from quietly leaving the lane.** Two guards, and only one of them
generalizes. Both read the same contract, `config/e2e_lane.yml` — **`total_specs` −
`quarantined` == `executed`** — so they can never certify two different suites.

**The numbers live in that file and are deliberately NOT repeated here.** They move
whenever a spec is added: this paragraph sat quoting 95 − 18 == 77 while the contract
climbed past 103, 107, 108, 110 and 112 — three of those bumps landed on one day
(2026-08-18). A count copied into prose is a second source of truth that nothing
enforces, and it rots within days while every guard stays green — the same disease as the ratchet-that-was-really-a-pin described just above, one
level out. Read the numbers from `config/e2e_lane.yml`; it is the only copy any guard
consults.

1. **The receipt (`bin/e2e-executed-set-check`, the `e2e_executed_set` CI job).** Each
   shard emits a JSON report; this job reads them and asserts what the lane **actually
   ran**: `executed` specs, 0 skipped, every shard's report present. This is the durable
   guard. A spec that leaves the lane by *any* route lands on one line of arithmetic,
   whatever syntax arranged it — a runtime skip, a widened `--grep-invert`, an
   `--only-changed`, a narrowed `testDir`, a deleted file, a dropped shard, or next
   year's flag nobody here has heard of.
2. **The static scan (`test/lib/e2e_quarantine_ratchet_test.rb`).** Reads the committed
   source and pins the **declared** set. It is the *fast* guard — it fails in
   milliseconds, before anyone burns six minutes of CI on a suite already provably
   wrong — and it is **not sufficient on its own**. Selection verbs (`only`/`skip`/
   `fixme`/`fail`) are refused on **any receiver**, and the e2e command's flags are
   **default-deny** — only `--shard`, `--grep-invert` and `--reporter` are allowed, because
   only those three cannot *shrink the selected set*. (`--reporter` is **not** "inert",
   which is what this line used to call it: it **emits the receipt** guard 1 is judged on.
   Drop `json` from it and the lane still runs every executed spec while the only evidence
   that it did evaporates — so it is separately pinned.) `--grep-invert` is value-pinned to exactly
   `@quarantine`.

**Why the receipt exists at all** — three rounds of review beat the static scan, each
time with a spelling the previous round had not imagined: `test.only` (collapses the
lane to one spec while the other shards select ZERO tests and **exit 0 in silence** —
sharding suppresses Playwright's own "no tests found" guard), then `test.skip`/`.fixme`,
then `testInfo.skip()` on a receiver the regex never watched, then a widened
`--grep-invert '@quarantine|board'` (51 specs → 43) that nothing pinned. The lesson is
structural, and it is worth carrying to any gate you build: **a guard that reads the
source can only refuse the spellings someone thought to refuse.** A
`const { skip } = testInfo` has no `.skip(` token in the spec at all and no regex will
ever see it — it is GREEN on the static scan today, deliberately, and RED on the receipt.
Assert what the system *did*, not what its source *looks like*.

`playwright.config.js` also sets `forbidOnly` under CI as a cheap hard stop at the lane
itself. So there are two honest moves for a red spec and no third: **fix it**, or
`@quarantine` it — which the ratchet makes you account for — and **block on it**.

## The Browser-Evidence Gate — When A Diff Ships Code No Tier Can See

**The rule.** If your diff ADDS an imperative browser program — an inline
`<script>` body, or a `.js`/`.ts` file under a served root — `bin/dor-check`
requires that a Playwright spec under `e2e/` changed with it. Nothing else in this
repo runs a browser, so nothing else can see that code work.

**Why it exists.** Three defects in 24 hours passed every automated gate and were
caught by a human or a reviewer opening a browser: a paint-time navbar jump
(`fix-navbar-offset-jump`), a timezone flag wrong in Chrome and Safari but not
Firefox (`local-at-time-format`), and a script swallowed by a phantom element so it
never ran in any browser (`propagate-at-format-gem`). Every tier the shapes demand
renders to a **String**.

**The sharpest lesson, and the one that sets what counts as evidence.** The guard
test for the third defect was `assert_includes html, "__atTimeFmt"` — and it
**passed on the broken page**, because the token survived inside the text the
phantom element swallowed. A test written to catch "stamps without a working
script" was itself an instance of the disease it named. So:

> **Browser evidence must observe the browser DOING something** — a computed style,
> a post-interaction DOM state, a `page.evaluate` result. A token appearing in
> markup is not evidence, in a Rails test *or* in a Playwright spec.

**It is targeted, not blanket, and every number here is reproducible** — run
`bin/measure-client-surface` (`--json` for machine-readable). Across **407 merged
feature units** (hub, studio-engine, turf-monster) it fires at blocking tier on
**9.3%**; in this repo it is **2.8%** (7 of 247), of which 3 would have been
refused. Two earlier cuts were measured and rejected: treating every
browser-executed construct alike made a bare Alpine directive **148 of 248
detections**, and blocking a rewritten script *body* took this repo from 2.8% to
**12.1%** and the corpus to 20.6% while catching none of the three motivating
defects. Both are the blanket rule wearing a detector's clothes.

| The diff | Verdict |
|---|---|
| Adds a **new** inline `<script>` block or touches a served `.js`, **repo has a lane**, no spec | **BLOCKS** |
| **Rewrites the body** of a script that already existed | reports |
| Adds a declarative binding (`x-data`, `data-controller`, `onclick=`) | reports |
| Changes a file that **carries** a script without adding one | reports |
| Adds a program in a repo with **no browser lane** (studio-engine) | reports, loudly |
| Mentions the word `<script>` **inside a comment** | **silent** |
| Server-only, or a template with no client construct | **silent** |

**It reads whole file versions, not hunks** — masked for comments, HEAD compared to
BASE. A hunk cannot tell a `<script>` tag from the word `<script>` in prose: the
disqualifying context (a `<%#` two lines earlier) sits outside it. Comments are
masked **non-greedily**, closing at the first `%>`, exactly as ERB itself parses —
so an ordinary comment is ignored while a comment that *terminates early* leaks its
script back into view and still fires. That second half is not hypothetical: it is
defect 3.

Programs block because they are arbitrary imperative code whose failure — a throw,
a wrong branch, a swallowed file — renders perfectly and does nothing. Bindings
report because their arguments are visible to the markup assertions already
written, and blocking the most common thing a UI diff adds would make the cheapest
shape the most expensive. The line is imperative-vs-declarative, not
important-vs-unimportant.

**"No evidence" and "no surface" are different answers.** The detector is strictly
positive: it fires only when it can point at the construct and print the file and
the line. If it cannot point, it says nothing — it never demands a spec it cannot
give a reason for.

**It is anchored on the roots this app SERVES from** (`app/views/`, `app/assets/`,
`app/javascript/`, `app/components/`, `public/`) — not on file extension. That is
load-bearing, not tidiness: `vendor/` is not in `.gitignore`, so in CI
`git ls-files --others` reports the entire vendored bundle as untracked, and a
vendored gem's `rescues/*.html.erb` is a real ERB template carrying a real
`<script>`. Shipped with the extension-only rule, the gate blocked three
previously-green `DorCheckTest` cases — **green locally, red in CI**, the same
signature as the `CHANGELOG.md` basename bite the release-owned-version gate
suffered in this same file. There is deliberately **no vendor denylist**: a denylist
needs a new entry for every packaging convention anyone invents, while the served
root excludes `vendor/`, `node_modules/`, `tmp/` and the next one nobody thought of,
all at once. If you widen `SERVED_ROOTS`, run the mutation harness — the explicit
test-root exclusion was already removed once it became provably dead code.

**studio-engine has no browser lane** — no `e2e/`, and `engine-ci.yml` installs node
but runs no browser (`consumer-ci.yml` runs consumers' `rails test` without
`test:system`). Two of the three motivating defects were there. Blocking would be a
refusal with no remedy, so the engine gets a loud named hole instead
(`/tasks/stand-up-engine-browser-lane`).

**The escape hatch is a record**, like `[full-suite-bypass]`:
`bin/task update <task> --checks "[browser-bypass] <reason>"` is honored and flagged
loudly, so the gate is routed around on purpose, in front of a reviewer.

Owned by `bin/lib/client_surface_diff.rb`; proven by
`test/lib/client_surface_diff_test.rb` (classifier) and
`test/lib/dor_check_browser_evidence_test.rb` (the gate actually asks it).

The Gate column names the branded testing gate whose attempt records that
lane's verdicts — attempt-aware GateRun rows with per-SOP results, rendered on
the task gates card (G1/G2) and the /deployments columns (G3/G4). The four
standalone gate docs live in [`gates/`](gates/g1-cert.md): `g1-cert.md`,
`g2-review.md`, `g3-candidate.md`, `g4-ship.md`.

If a lane fails, record the classification in task `qa_feedback`:

- real regression
- unrelated existing failure
- flaky infrastructure
- stale branch
- missing seed or test data
- dependency ordering issue

## A Test Whose Child Resolves The Session Must Null It

**The rule.** A test that spawns a child able to resolve `SessionIdentity` —
any `bin/` command, or anything else that reads the session env — must build
the child's env through the shared neutralizer:

```ruby
require_relative "../support/session_env"   # standalone minitest files
                                            # (test_helper requires it for Rails-side tests)

env = SessionEnv.neutralized("FOO" => "bar")            # FOO set, session UNSET
out = IO.popen(env, cmd, &:read)
Open3.capture2(SessionEnv.neutralized, *cmd)            # bare overlay
SessionEnv.neutralized("CLAUDE_CODE_SESSION_ID" => sid) # opt IN to a fake session
```

Session-blind spawns are exempt: `git` reads no session var, so the tests that
shell out to it (`fast_cert_test`, `repo_root_test`) rightly skip the
neutralizer. Backticks and `%x` take no env hash at all — use them only for
session-blind children, and switch to a spawner that can pass an env before the
child grows session-aware. When unsure, neutralize. The one spawn that must stay
bare is one that deliberately asserts session inheritance (`Release::GateEnvTest`).

**Why.** An interactive Claude session exports `CLAUDE_CODE_SESSION_ID` (Codex:
`CODEX_THREAD_ID`); **CI and a plain shell export neither.** A spawned `bin/task`,
`bin/fast-check`, `bin/dor-check`, `bin/pr-review` or `bin/agent-activity`
inherits the var, so `SessionIdentity` (`bin/lib/session_identity.rb`) resolves
the **operator's live session** where CI resolves none. Actor/persona defaulting
takes the wrong branch and best-effort narration shells out to the real board
mid-test — so the test **false-fails for the agent running it by hand, while
staying green on CI.** That asymmetry is what hides the coupling: this bug class
was independently rediscovered at least three times, and once red-flagged
genuinely-green code at a release gate. Green on CI is not proof; run the suite
from a live agent session.

**`nil` means UNSET — never `""`.** A nil value removes the key in the child
(`Process.spawn` semantics). A literal empty string is still **exported**:
`SessionIdentity` happens to treat a blank id as absent, but any reader keying on
*presence* (`ENV.key?`, a shell's `${VAR+set}`) sees a session that isn't there.
`SessionEnv.neutralized` normalizes a blank session override to unset for you.

**Two neutralizers, held in lockstep by a test — not by trust.** `SessionEnv`
(`test/support/session_env.rb`) covers tests, including an agent running
`bin/rails test` by hand in a worktree. `Release::GateEnv`
(`app/models/release/gate_env.rb`) covers the release gate's own spawn env. They
are deliberately not shared code — `SessionEnv` must load in a bare
`minitest/autorun` file with no Rails — and the dependency runs **one way only**:
a test may require `Release::GateEnv` (it is pure and Rails-free by construction,
exactly as `bin/release.rb` requires it), but production code never reaches into
`test/`.

That leaves one real hazard, **drift between the two key lists**, and it is closed
mechanically rather than by prose: `SessionEnvTest`
(`test/lib/session_env_test.rb`) requires `Release::GateEnv`, asserts the two
`SESSION_KEYS` lists are **equal**, and asserts every production key is genuinely
absent from a spawned child. Add a key to **either** list alone and the suite goes
red — so add it to both. Each side's nil-means-unset semantics is covered by its
own test (`SessionEnvTest`, `Release::GateEnvTest`).

## A Test Whose Child Can Reach The World Must Be Sealed Too

**The rule.** Nulling the session stops a child resolving the operator's
*identity*. It does nothing about the child's *reach*. Any test that spawns a
`bin/` command also builds its env through the outbound floor
(`test/support/outbound_seams.rb`), in the harness's **shared** spawn helper:

```ruby
require_relative "../support/outbound_seams"

def command_env(extra = {})           # ONE helper, every spawn in the file
  OutboundSeams.env({ "PROJECTS_DIR" => @projects_dir }.merge(extra))
end
```

`OutboundSeams.env` is `SessionEnv.neutralized` plus the floor: the three board
URLs at an unroutable loopback port, a recording refusal first on `PATH` for
`gh` / `op` / `heroku`, the named binary seams (`CI_STATUS_GH_BIN`,
`GH_AUTH_TOKEN_BIN`), and `GIT_SSH_COMMAND` / `GIT_ASKPASS` for git's two reach
paths. Your overrides merge **last**, so a test that plants its own fake or
points at a stub server it owns still wins.

**Why.** `bin/task` resolves `ENV.fetch("TASK_API_BASE", "https://mcritchie.studio")`
— **production is the default** — so an unpinned child authenticates against and
**writes to the live board**. And a leaked `gh` call does not fail quietly: an
auth-shaped refusal arms `GhAuthRetry.mint` → `bin/gh-token` → `op read` against
live 1Password → a POST that mints a **real App installation token**. Measured
2026-08-14: a plain `bin/rails test` could do both. Neither is a test failure —
**both are silent successes**, which is exactly why they survived review.

**The floor is armed process-wide, not opt-in.** Requiring
`test/support/session_env.rb` (which every spawning test already does) pins
`TASK_API_BASE`, `ATOMIC_CAPTURE_URL`, `TASK_BOARD_URL` and `GH_AUTH_TOKEN_BIN`
for the test process, and every child inherits them. Adoption file-by-file would
leave the floor missing in precisely the files nobody audited. Note the operator
is a plain assignment, **not `||=`**: an agent shell exports
`ATOMIC_CAPTURE_URL=https://mcritchie.studio`, so deferring to the ambient value
would preserve production and arm nothing. Opt out of a deliberate live run with
`OUTBOUND_SEAMS=off`.

**Prove every pin with a positive receipt.** A pin nobody exercised is advice: it
reads as containment, it is never on the path, and the leak continues underneath
it. So each sealed stub **records** what it refused, and the harness asserts the
receipt — drive the shape that reaches for production, then assert the sink or the
stub *received* the call:

```ruby
OutboundSeams.reset!
agent_worktree!("bind-task", "mcritchie-studio", @task, "seam-proof-task")
refute_empty OutboundSeams.calls_to("task-cli")   # the seam IS on the path
```

The reference implementations are `OutboundSeamsTest`
(`test/lib/outbound_seams_test.rb`), the harness self-tests in
`test/commands/agent_worktree_test.rb` and `test/lib/dor_check_test.rb`, and the
loopback-sink pattern in `test/lib/dor_check_browser_evidence_test.rb`. **Never
assert the absence of a symptom instead** — every leak this floor closed was
green before and after.

**Pin a drift guard against the live constant, never a literal copy of the list.**
A literal only pins the side it is written on, so the *other* side can grow a key
while every check stays green — which is exactly the leak these helpers exist to
prevent.

## Running Tests By Path Skips The Asset Build

`bin/rails test test/models/widget_test.rb` does **not** behave like a bare
`bin/rails test`. Rails runs its `test:prepare` task only when **no argument
looks like a path** — `Rails::Command::TestCommand` guards it with
`run_prepare_task if self.args.none?(EXACT_TEST_ARGUMENT_PATTERN)`, and that
pattern matches file paths and `-n`/`--name` filters. `test:prepare` is the
standard hook a CSS/JS bundler enhances (`tailwindcss-rails` does
`Rake::Task["test:prepare"].enhance(["tailwindcss:build"])`), and it is the only
thing that builds `app/assets/builds/tailwind.css`. **`db:test:prepare` does not
build it** — tailwindcss enhances that task only as a fallback, for apps where
`test:prepare` is undefined, which it never is in a Rails app.

`app/assets/builds/` is **gitignored** (only `.keep` is tracked), so every virgin
checkout starts with no built CSS. Put those two facts together:

| Runner | Invocation | `test:prepare` runs? | Virgin tree |
|---|---|---|---|
| GitHub CI | **sharded**: `bin/ci-shard --shard=i/4` × 4 (`rails`) + `bin/rails db:test:prepare test:system` (`system`), audited by `bin/rails-executed-set-check` (`rails_executed_set`) | yes | green |
| `bin/full-suite-check` | the single command whose scope is CI's Ruby suite — today `bin/rails db:test:prepare test test:system` (rake-routed; resolved by `bin/lib/ci_test_command.rb`, which tolerates the sharded split because the shards ∪ `system` are a subset of it) | yes | green |
| Release gate workspace — **hub** | `bin/rails db:test:prepare test test:system` (the hub's registry `test_cmd`/`qa_test_cmd` — rake-routed, and rake's `test` shells an **argless** `rails test`) | yes | green |
| Release gate workspace — **satellites** | `bin/rails test test/integration` (`qa_test_cmd`, `config/release_repos.yml`) | **no** | green — the gate preps the env itself (PR #522) |
| **`bin/fast-check`** | `bin/rails test <mapped/spine paths>` | **no** | **was red** |
| **Playwright `webServer`** — the `e2e` lane | `bin/rails db:test:prepare && … && bin/rails server -e test` (`playwright.config.js`) | **no** | **was red** — green since PR #543 added an explicit `bin/rails tailwindcss:build` to the chain |
| A hand-run single file | `bin/rails test test/x_test.rb` | **no** | **was red** |

The red is `The asset "tailwind.css" is not present in the asset pipeline` on
every view-rendering test — dozens of errors on a diff that never touched a
view, which reads as a phantom regression. The three runners this repo owns now
prepare the test env themselves — `bin/fast-check`'s `test-prepare` lane,
`bin/agent-worktree`'s `prepare_test_env` (run by `new` at bringup, by `up`, and
by `test <file>`), and the Playwright `webServer` chain in `playwright.config.js`
— so their failure is designed out rather than documented around.

The Playwright lane was the newest to learn this, and it learned it in public:
the `e2e` job was green on a laptop that had run `test:prepare` by hand and red
on every clean CI runner, with all 69 specs failing assertions that had nothing
to do with CSS. `db:test:prepare` alone does **not** build the bundle; only
`test:prepare` (the hook `tailwindcss-rails` enhances) does, and Playwright's
`webServer` boots the server directly rather than through the argless `bin/rails
test` that would have gotten it for free. Hence the explicit `bin/rails
tailwindcss:build` in the chain — ~0.4s, and load-bearing.

**The release gate workspace was fixed the same way** (task
`gate-workspace-skips-test-prepare`, PR #522, shipped): `prepare_gate_workspace!`
(`bin/release.rb`) now runs `bin/rails db:test:prepare test:prepare` before both
the G3 and G4 lanes, so a `.worktrees/_gate` — created virgin by
`git worktree add --detach` — has its bundled assets built whatever shape the
registered command takes, the satellites' path-arg `qa_test_cmd` included.
(turf-monster was the live exposure: `tailwindcss-rails`, gitignored
`app/assets/builds/*`, `stylesheet_link_tag "tailwind"` via studio-engine's head
partial — its G3 gate took exactly this false red before #522.) With the prep in
place, a gate red on a missing asset is no longer this bug: `test:prepare`
builds the stylesheet up front, so treat such a red as a real signal — most
plausibly a broken stylesheet in the release's own diff (a bad `@apply`, an
unknown utility, a malformed `@theme`) — and read the gate's captured output to
tell an env gap from a diff regression.

Two rules follow:

- **A cert lane that hits an ENV gap must say so, not fail as a test.** A gate
  that red-flags green code teaches agents to distrust and route around it. The
  inverse lies too: do not report a real diff regression (a broken stylesheet
  fails the asset build) as an ENV gap.
- **If you add a lane that runs tests by path** (anywhere: a new bin script, a
  gate workspace, a CI job that shards by file), prepare the test env first —
  `bin/rails db:test:prepare test:prepare`, one boot. `test/lib/tasks/test_prepare_asset_hook_test.rb`
  pins the hook that makes this work.

## A Synthesized Click Lands At COORDINATES — So Wait For The Target To Stop Moving

**`find(...).click` does not click an element. It clicks a POINT.** The driver
hit-tests the element, then dispatches `pointerdown` and `pointerup` at that
point. If the page reflows in between, the two land on different elements, and
the browser fires `click` on their nearest **common ancestor** — never on the
button. Nothing raises. `ElementClickIntercepted` does not fire, because at
hit-test time the element really was there. The handler simply never runs, and
the test fails later, on whatever it asserted about the click's effect.

**This cost three PRs in one day** (`close-board-filter-flake`).
`TasksBoardFilterSystemTest` reddened on #886, #895 and #897 — two sessions,
unrelated diffs — always on the same negative assertion, `expected not to find
visible css "#card-rolio-tasks-board-card"`. The card was innocent. The captured
event sequence:

```text
pointerdown -> SPAN "rolio"     (the filter chip)
pointerup   -> SPAN "Apps"      (the row label; the chip has moved)
click       -> DIV              (their common ancestor)
```

**What moves it: a third-party webfont.** Page text is set in Montserrat, fetched
from `fonts.googleapis.com`. The stylesheet blocks the load event; the font
FILES do not. So they arrive after `visit` returns, every glyph is re-measured,
and each chip changes width — inside the ~60 ms a test spends asserting
readiness, finding a control and clicking it. Measured locally: the chip is found
at 45 ms and clicked at 68 ms.

**Why five local reproductions all came back green.** On a dev machine that font
is already cached, so the reflow happens before the test looks. On a CI runner it
is a live network fetch. A flake that only reproduces where the network is real
is not "CI being flaky" — it is a real timing dependency that CI is honest about
and your laptop hides.

**The rule: use `click_when_settled` for any control clicked soon after a page
load.** It blocks until the target's box is identical across two consecutive
samples AND nothing is left in flight that could still resize it, then clicks.
Both halves are load-bearing — stability alone clears a box that has simply not
been re-measured yet; readiness alone clears a box mid-animation. Plain
`find(...).click` stays correct once the page has been interacted with.

**Ask `document.fonts.check` about the ELEMENT's own font, not the document's.**
`document.fonts.status` reads `"loaded"` while two dozen declared faces are still
`"unloaded"`, because a face only loads when something needs it — measured on this
board: status `loaded`, 25 of 30 faces `unloaded`. The global signal will wave you
through a page that is still about to reflow.

**Assert the control's own state before its consequence.** The chips carry
`aria-pressed`, so a swallowed click now fails on the chip, naming itself, instead
of downstream on a card assertion that cannot distinguish "the click never landed"
from "the filter toggled and the view did not react". A negative assertion is the
worst possible place to learn a click went missing.

`test/system/board_filter_click_stability_test.rb` pins the guard by making the
race deterministic: it puts the page into a settling window that moves the chip
every frame and reflows it under any pointerdown, then closes. Swap
`click_when_settled` for `find(...).click` and it goes red on the `aria-pressed`
assertion, which is the production signature exactly. **Verified by mutation, 3
red / 3 green** — the only proof that counts for a timing fix, because the broken
state also passed most of the time.

**The user-facing half is FIXED — in the engine, not by the guard.**
`layouts/studio/_head.html.erb` in studio-engine now vendors Montserrat through
the asset pipeline, joining the Alpine, SortableJS and confetti that file already
served itself. Same bytes, pinned at Google Fonts v31, and declared
`font-display: optional` rather than `swap` — which is the substance of it, because
`swap` has an unbounded swap period, so a late font reflows the page no matter who
serves it. Landed as `/tasks/vendor-the-montserrat-webfont` (studio-engine #172);
it is on `accepted` and rides the next release sweep into the app.
**The guard still earns its keep.** It defends any control clicked soon after a
load against every other source of reflow, and one font is not the only thing that
can move a box.

### A desk that does not own its test DB may not run a CERT lane

`bin/fast-check` / `bin/full-suite-check` **refuse** in a desk whose test database is
the repo's **shared** one — `bin/lib/desk_guard.rb`. The cert would otherwise run
against the database the primary checkout and the release gate workspaces use, and
`full-suite-check`'s first lane (`db:test:purge`) would **destroy** it mid-suite.

**It PROVES the property, it does not trust a declaration.** The guard boots the app in
the desk at `RAILS_ENV=test` and reads back the database it *actually* connects to
(`connection_db_config`, which opens no connection), then compares that against the
repo's shared test database — computed externally from `config/database.yml` with the
**ERB stripped**, so no env var can rewrite the thing being compared against.
Adapter-agnostic:

| adapter | isolated when… |
|---------|----------------|
| `postgresql` | the resolved database **name** is not the shared `<app>_test` |
| `sqlite3` | the resolved database **file** resolves **inside the desk** (rolio — private by construction, and it needs no `TEST_DATABASE_URL` at all) |

It **fails closed** *for a Rails desk*: if it cannot prove isolation either way — the app
will not boot, `config/database.yml` is unreadable — it refuses and says so.

**It only applies where there is a test DB to protect.** A repo that is not a Rails app —
a gem or Anchor desk (`studio-engine`, `solana-studio`, `turf-vault`) with no `bin/rails`
and no `config/database.yml` — has no shared `<app>_test` and no `db:test:purge` hazard, so
the guard is **inapplicable and admits without booting**. This is emphatically **not**
"the boot failed, so allow": the line is drawn on the repo carrying a Rails marker, never
on the boot outcome, or a Rails desk whose boot broke for any unrelated reason would fail
*open* — the exact hole this guard closes. Inapplicable (no Rails app) ADMITS; unprovable
(a Rails app we cannot resolve) REFUSES.

**Why not just check for `TEST_DATABASE_URL`?** Because that is a *declaration*, and it
only lands if the app's `config/database.yml` actually reads it. It is a hand-rolled seam:
the hub renders `url: <%= ENV["TEST_DATABASE_URL"] %>`; turf-monster did **not** for a
period, so every turf desk declared an isolated-looking URL, resolved to the **shared**
`turf_monster_test`, and a presence-checking guard said ALLOW — while the next lane purged
it, with two turf desks live. A guard that reports an isolation it has not proven launders
a live hazard into a claimed-closed one: **worse than no guard**. Any app added to the
managed set needs that `url:` line in its `test:` block, or its desks are refused.

**Scope, stated exactly:** enforcement lives in the two **cert runners**. A plain
`bin/rails test` in a desk is **not** guarded — it is safe because bringup provisions the
isolated DB, not because something stops it at the door. Two residuals are stated rather
than hidden in `bin/lib/desk_guard.rb`: it proves "not the SHARED database", not "not
*any other desk's* database", so two slugs that truncate to the same bounded Postgres
identifier would both be admitted; and a `TEST_DATABASE_URL` inherited from *another
desk's* shell resolves to a database that is private to somebody else, and is admitted.

If you see the refusal it is an **env/config issue, not a regression in your diff**. It
names which of the two it is: re-provision (`bin/agent-worktree new <app> <slug>`) when
bringup did not complete, or fix the repo's `config/database.yml` when the pin is inert.
See [worktrees.md](worktrees.md).

## The Minitest DB Starts EMPTY — And The E2E Lane Must Not Share It

**The minitest database is hermetic by construction.** `test/test_helper.rb` runs
`TestDatabasePurge.purge!` at load (and again inside each parallel worker),
truncating **every** application table before fixtures load. Rails only truncates
the ~28 tables it has fixtures for; the other ~45 kept whatever any other process
committed. The e2e lane committed exactly that — `playwright.config.js`'s
`webServer` runs `e2e/seed.rb` against the SAME test DB under `RAILS_ENV=test` —
and its un-fixtured rows (pokemons, releases, task_events, …) broke minitest tests
that never went near e2e. A builder then hunts a phantom regression in their own
diff. **You no longer hand-reset the test DB after e2e work.**

**The reverse hazard is now WIDER, and it is not yet closed.** `playwright.config.js`
still seeds and serves against the same test DB, and `reuseExistingServer: !CI`
keeps a local e2e server alive between runs. A minitest boot used to truncate the
28 fixtured tables out from under a live e2e server; it now truncates all ~73. So:

> **Do not run the minitest suite and the e2e lane concurrently against the same
> database.** Until e2e owns its own DB (the producer-side fix — deferred), the two
> lanes share one, and whichever boots second empties the first one's world.

**The purge FAILS CLOSED — copy this shape.** A routine that empties every table
must *prove* its target before it fires, because the harness does not guarantee it:
`ENV["RAILS_ENV"] ||= "test"` does **not** override an already-exported `RAILS_ENV`,
and `rails/test_help` aborts only on production — so `RAILS_ENV=development bin/rails test`
boots the suite straight onto the shared development database. `TestDatabasePurge`
therefore refuses (raises `UnsafeDatabase`) unless **both** hold: `Rails.env.test?`,
**and** the database read back from the live connection is the `database:` literal
`config/database.yml` declares for `test`, or a legitimate derivative (`…-0` clones,
`…_<worktree>` isolated DBs, and the release workspaces' `<app>_gate_test` /
`<app>_ship_test`). Same doctrine as the release gate's `assert_private_gate_db!` —
*ask the booted app, and treat a foreign DB as a hard abort, never a silent stomp.*

**Widening that admission list is the hazard — keep it an EXACT set.** The release
workspaces infix their role *before* `_test` (`mcritchie_studio_gate_test`), so they do
not start with the base (`mcritchie_studio_test`) and the guard's first cut REFUSED the
release gate's own database — bricking every release the day it landed (2026-07-14). The
fix admits those two names **by equality, derived from the base**, and nothing else:
relax it into a prefix or substring rule and `mcritchie_studio_development` is admitted
too, which is the exact database this guard exists to spare. `test/lib/test_database_purge_test.rb`
pins both directions — the workspace DBs are admitted (against the names
`Release::GateWorkspace` actually mints, so a new role goes red there instead of in a
release), and foreign look-alikes (`…_gate_testing`, `…_deploy_test`, `other_app_gate_test`)
are still refused.

**Anchor the expectation in something the ENV var cannot move.** The obvious check —
"connected DB == `configs_for(env_name: "test").database`" — is a **placebo**, and it
was measured as one on this app: Rails merges `DATABASE_URL` into the config *for the
current env*, and under the suite that env **is** `test`. So `RAILS_ENV=test
DATABASE_URL=…/mcritchie_studio_development` rewrites the **test** config to the dev DB;
connection and expectation both read `mcritchie_studio_development`, the equality
passes, and the purge stomps the shared dev DB. Comparing a value against a config the
same ENV var just rewrote is comparing a moved value **to itself**. The `database.yml`
literal does not move — anchor there. (`test/lib/test_database_purge_test.rb` pins this:
swap the anchor back to `configs_for` and the "placebo case" goes red.)

### …and it STAYS empty: the mid-run leak guard

**A boot purge is a starting condition, not an invariant.** It cannot see a leak
that happens *after* it runs, and the run is full of moments that can leak: a test
with `use_transactional_tests = false` (its writes are really committed), or a
subprocess committing to the same database. Rails will not clean those rows —
fixture loading only truncates the ~28 tables it has fixtures for — so every later
test in that process sees them.

**The victim is never the polluter, and that is what makes it expensive.** The one
test that notices is the standing invariant
(`test/integration/test_database_hermeticity_test.rb`), which belongs to whoever's
diff happens to be in flight. It went red as `task_events: 1 row(s)` in three
unrelated tasks, and only *sometimes*: minitest shuffles the runnable classes, so
the same SHA re-ran green. It reads exactly like flake, and it cost three sessions
— one of them an hour of infrastructure time on a confident wrong hypothesis.

**So the rule is enforced where the blame belongs: a test may not leave rows in an
un-fixtured table.** `test/support/test_database_leak_guard.rb` checks after EVERY
test and fails the test that dirtied the database, naming the table, the count, and
the usual cause. Two details make it cheap and correct:

- It runs **after Rails' rollback** — installed on `ActiveSupport::TestCase`, which
  sits ahead of `ActiveRecord::TestFixtures` in the ancestor chain, so `super`
  returns only once the test transaction is gone. An ordinary transactional test's
  own writes have already vanished by then, so anything still standing was really
  committed. (A second hook on `Minitest::Test` covers the bare `test/lib` /
  `test/commands` files when the sweep loads them alongside Rails.)
- It asks with **one round trip** — `TestDatabasePurge.nonempty_tables` is a single
  `UNION ALL` of `EXISTS` probes (~0.24 ms measured), not a `COUNT(*)` per table
  (~3.4 ms). Counts are computed only on the failure path, where they are the report.

It also **truncates what leaked** before returning. That is containment, not the
fix: one leaky test can no longer poison the rest of the run, which is what removes
the ordering lottery from the invariant above.

**Writing a non-transactional test: clean up what the CALLBACKS wrote, not just
what you wrote.** The bug this guard was built on is the whole lesson —
`ReviewPendingActionSettleRaceTest` created a Task (whose `after_create
:record_genesis_event` writes a TaskEvent) and cleaned up with `Task.where(slug:
…).delete_all`. `delete_all` skips callbacks **and** `dependent: :destroy`, so the
event outlived its parent, once per test. CI distributes test *methods* across
workers, which is why a worker that drew one of the file's two tests ended with
exactly the one row the CI log named. Delete the children explicitly, or destroy
the parent.

**Fixtured tables are deliberately outside its reach.** Truncating them would empty
the world the rest of the process depends on, and it is unnecessary: the
non-transactional branch of `setup_fixtures` calls `invalidate_already_loaded_fixtures`,
so the harness re-loads fixtures itself. Only the un-fixtured tables have no owner —
which is the same blast radius the boot purge and the standing invariant use.

`test/integration/test_database_leak_guard_test.rb` pins it by RUNNING a real
non-transactional test case in-process and reading its result: the leaky shape must
FAIL with the table named, the same case with a complete cleanup must PASS, and the
database must be empty afterwards either way. Ordering is not left to the suite —
the polluter and the check are one call apart.

### Stranded per-run cert test databases are reaped

One test provisions a **real** Postgres database to exercise db provisioning end to
end (the worktree DB-name overflow probe in `test/commands/agent_worktree_test.rb`).
It mints a **unique per-run** name (`mcritchie_studio_test_<slug>_<8hex>`) so concurrent
runs can't corrupt each other, and drops it in an `ensure`. But an `ensure` does **not**
run under SIGKILL — and parallel certs here *have* hit SIGKILL/SIGSEGV — so every hard
kill would strand a distinct database that nothing reclaims: a slow but unbounded leak.

`test/support/cert_database_reaper.rb` (`CertDatabaseReaper`) closes it. The mint site
writes a **lease** naming the database and the owning PID before provisioning; a clean
run drops the DB and clears the lease, a hard kill leaves both. Leases live in a
**durable, per-user host dir** (`~/.mcritchie/cert-db-leases`), NOT a worktree's own
`tmp/` and NOT `Dir.tmpdir` — a per-worktree lease vanishes when that worktree is cleaned
up, and a `Dir.tmpdir` lease is pruned by the OS temp-cleaner; either way the database it
named is stranded on the shared cluster as permanently unreapable. A per-user home dir
survives worktree cleanup, temp sweeps, and reboots, and still lets every run's boot sweep
see every other run's leases. The reaper acts **only**
on databases named in a lease it wrote (a name pattern can't be the identity — a
long-slug worktree's test DB has the same `_<8hex>` shape), drops those whose leasing PID
is provably gone (a false-alive only ever leaks; a false-dead is impossible for a
per-run-unique DB), re-proves each name is a `<base>_<slug>_<8hex>` test database before
dropping — never `mcritchie_studio_development` — and **keeps the lease when a drop
fails** so a later sweep retries. It runs two ways:

- **on every suite boot** (`test/test_helper.rb`, once, best-effort) — the periodic
  sweep; a DB blip never fails the suite.
- **`bin/reap-cert-databases`** — a standalone/manual sweep (boots the app, prints
  `reaped`/`skipped`/`failed`/`refused` counts).

`test/lib/cert_database_reaper_test.rb` pins the guard (the dev DB and no-slug
look-alikes are refused; a failed drop keeps the lease), and
`cert_database_reaper_integration_test.rb` proves the drop/skip end to end against a real
cluster.

## A Test May Never Write The Operator's Real `.agents` State

The `bin/` stack keeps **seven** stores **outside** the repo, under the real
projects root, and every one of them is resolved by the same **fallback** — an
env var, else a path under the operator's real `<projects>/.agents`:

| store | pinned by | falls back to | written by |
|-------|-----------|---------------|------------|
| usage/cost baselines | `TASK_USAGE_DIR` | `<projects>/.agents/task-usage` | `bin/task`, `bin/release`, `bin/reviewer-select` |
| narration markers | `CLAUDE_PROJECTS_DIR` | `<projects>/.agents/sessions` | `bin/task`, `bin/atomic-event`, `bin/devops-shift`, `bin/statusline` |
| agent-API token cache | `CLAUDE_PROJECTS_DIR` | `<projects>/.agents/atomic-capture` | `bin/lib/agent_api.rb` (every AgentApi consumer) |
| conductor locks | `MCR_PRIMARY_LOCK_DIR` | `<projects>/.agents/locks` | `bin/release` |
| worktree registry | `AGENT_WORKTREE_REGISTRY` or `PROJECTS_DIR` | `<projects>/.agents/worktree-registry.json` | `bin/agent-worktree` |
| DB-allocation flock | `AGENT_WORKTREE_LOCK` or `PROJECTS_DIR` | `<projects>/.agents/agent-worktree.lock` | `bin/agent-worktree` |
| Redis band | `AGENT_REDIS_CAPACITY_FILE` or `PROJECTS_DIR` | `<projects>/.agents/redis-capacity.json` | `bin/agent-worktree` |

**Do not maintain this table by hand.** `lib/task_usage_sandbox.rb`'s `STORES` is
the source of truth, and `test/lib/state_store_containment_test.rb` re-derives the
family **from the source** on every run — an eighth store, or a new writer of an
existing one, fails the suite rather than joining a list nobody updated. (Both
leaks below were closed store-by-store, and each fix left live unguarded writers
behind. That is what the containment test exists to stop.)

A test that spawns any of those CLIs and pins nothing hands its child the
**operator's live store**. Neither leak below was theoretical:

- **The cost store.** `task_cli_test.rb` pinned nothing, and its `SESSION`
  constant is a **real past session id** whose 30MB transcript still sits in
  `~/.claude` (HOME was unpinned too), so `bin/task create` under the suite
  globbed that transcript and wrote its ~1.9-billion-token totals into the real
  cost store under the stub slug `demo-task`. Measured `$cost` derives
  `actual_size` and seeds the reviewer-select baselines, so a fixture row skews
  the sizing intelligence.
- **The narration store.** `statusline_test.rb#render_in` pinned neither
  `CLAUDE_PROJECTS_DIR` nor `HOME` on a `stage: "building"` context, so for ~3
  weeks **every suite run** re-wrote a 0-byte `<session>.heartbeat` into the
  operator's live sessions dir and fired the real `bin/task heartbeat` at the
  **production board** — at a **real production task**, because the fixture named
  one. Pin your roots; and never let a fixture name a live record.

**The rule, in two halves — you need both.**

- **Configured.** Pin all three (`TASK_USAGE_DIR`, `CLAUDE_PROJECTS_DIR`, `HOME`)
  into a tmpdir. `TaskUsageSandboxEnv.child_env(tmpdir)` builds them:

  ```ruby
  env = SessionEnv.neutralized(TaskUsageSandboxEnv.child_env(root).merge("FOO" => "1"))
  ```

  `HOME` is not optional — it is the **read** half. An unpinned HOME lets a child
  glob whatever real transcript matches its fixture session id.

- **Asserted.** Requiring `test/support/session_env.rb` arms `TASK_USAGE_SANDBOX`
  for the whole test **process**, and Ruby hands a process's env to every child it
  spawns — so *every* test child inherits it, including one written years from now
  by someone who never read this page. With the sandbox on, `TaskUsageSandbox`
  (`lib/task_usage_sandbox.rb`) makes the CLI **fail closed**: an unpinned store
  **aborts** the command instead of falling back, and any resolved path inside the
  real `<projects>/.agents` is refused whatever pointed it there. A pin you have
  to *remember* is the bug; the guard is the half that cannot rot.

- **Contained.** The two halves above only bind a caller that actually reaches the
  guard — and *twice* now, the caller that leaked never did. `bin/atomic-event`
  took the marker store's pure path **builder** and hand-rolled a raw `File.delete`
  beside a guarded sibling that did the same job correctly; no amount of testing the
  guarded surface could see it. So the containment is asserted **against the tree**:
  `test/lib/state_store_containment_test.rb` refuses (1) any file outside a small
  sanctioned allowlist that so much as **constructs** a path under `.agents`, in any
  spelling, and (2) inside that allowlist, any method that **holds** a raw store path
  without laundering it through `TaskUsageSandbox.enforce!`.

  **It guards the precondition, not the verb — you cannot write to a path you never
  named.** Nothing in the scan looks at what a method *does* with a path, so
  `system("rm #{p}")`, `Pathname#delete`, `File.binwrite` and a spelling nobody has
  invented yet are all refused for the identical reason a `File.write` is: the method
  held the path. There is no list of IO verbs that can be incomplete.

  That is a correction, not a boast. The **first** version of this test did enumerate
  the sinks, and it leaked exactly as an enumeration must: a `bin/leaky-demo` deleting
  the operator's live `.open-activity` with an **ordinary interpolated path** ran
  against it **green**. Enumerate the spellings and you refuse only the spellings you
  thought of; assert the precondition and you refuse the class. **A guard that only
  guards the callers — or the verbs — you remembered is a naming convention.**

  Two limits it states about itself, because a guarantee oversold is worse than none:
  `bin/statusline` is **bash** and no Ruby source scan can read it, so its containment
  is proven at the **boundary** instead (the test executes it armed + unpinned and
  observes that the real store does not change); and a program that *computes* its own
  path string defeats any text scan, which is the same lane's job.

A violation exits via `abort` (SystemExit) **on purpose**. Every caller of this
state is best-effort (`rescue StandardError => nil`, so a usage hiccup can never
kill a stage transition), and a violation raised as a `StandardError` would be
swallowed by exactly those rescues — a guard that degrades to a silent no-op is
not a guard.

**In-process writers need the pin too — not only spawned children.** Rule 1
checks the **ENV pin** at the write seam, even for a write aimed at an explicit
tmpdir `dir:` — by the time a path reaches `TaskUsageBaseline#write`, a CLI's
env-fallback dir looks exactly like a test's explicit one, so the pin is the only
tell the guard has. A test that calls the baseline **in the test process** (e.g.
`task_usage_baseline_test.rb`) must set `ENV["TASK_USAGE_DIR"]` to a tmpdir in
`setup` and restore it in `teardown`, or its first write aborts the whole
combined `bin/rails test` run — green alone, red in any process where a sibling
file armed the sandbox.

**Finding what already leaked.** `bin/task usage-audit` is a read-only sweep of
**the cost store only** — it reports rows keyed by a slug only a test stub serves
(`demo-task`, `cli-board-sample`), exits 2, and never purges: a baseline is
indistinguishable at the file level from real operator state, so removing one is
the operator's call. Note the signal is the **slug, not the size**: a stored row
is the session's *cumulative* totals, so a long real session banks a
billion-token baseline legitimately and magnitude proves nothing.

**The other six stores have no audit sweep.** `usage-audit` does not look at them,
so do not read a clean run as "nothing leaked" — it answers one store's question.
The narration store alone holds over a hundred `.heartbeat` files and dozens of
`.activity-usage.json` files under `<projects>/.agents/sessions` — count them
yourself rather than trusting a number in a doc, which is the same discipline this
section is arguing for:

```bash
ls "$(cd ~/projects && pwd)/.agents/sessions" | sed 's/.*\.//' | sort | uniq -c | sort -rn
```

A leaked marker is not distinguishable from a real one by inspection either. Residue is the
**operator's** call to clear; the guard's job is to stop new residue, and the
containment test's job is to stop a new *writer*. If you want a sweep for the other
stores, that is unbuilt work — say so plainly rather than implying coverage that
does not exist.

## Test Suite Catalog

`bin/devops-tests` reads `config/devops_test_suites.yml`. Each suite should
include:

- `lane`: `pr_review_gate`, `local_proof`, `qa_acceptance`,
  `production_smoke`, `nightly_deep`, or `quarantine`
- `environment`: local, QA, devnet, or production target
- `trigger`: when the suite should run
- `command`: the command or command template
- `blocks_merge`: true only for PR review gates that should prevent merge
- `mutates`: true when it creates or changes data
- `notes`: risk and setup context

Update the catalog when a suite, trigger, deploy-smoke command, or app joins
the managed stack. Fresh Avi sessions can run:

```bash
bin/devops-tests --app turf-monster
bin/devops-tests --app mcritchie-studio --lane pr_review_gate
bin/devops-tests --lane qa_acceptance
```

## McRitchie Studio

```bash
bin/rails test
npm test
```

> **Running the Rails suite from an agent shell.** `bin/agent-runtime install`
> manages a small `~/.zprofile` Ruby PATH block so Codex Bash tools and other
> non-interactive zsh login shells prepend
> `/opt/homebrew/opt/ruby@3.3/bin:/opt/homebrew/lib/ruby/gems/3.3.0/bin` while
> preserving normal command lookup. `bin/agent-runtime doctor` verifies the zsh
> startup file, login-shell `ruby`, Bundler, and Rails boot path. If an
> already-open session still resolves system Ruby 2.6, restart Codex or
> temporarily run
> `export PATH="/opt/homebrew/opt/ruby@3.3/bin:$PATH"`. Parallel test workers
> fork-clone the test DB, which **deadlocks or segfaults the `pg` gem on macOS**
> (a Ruby crash report, not a test failure) — pg fork-safety. So as of PR #169 the
> suite runs **single-process locally by default** (`test_helper.rb` →
> `TestParallelism.worker_count`: parallel only when `CI` is set), so a plain
> `bin/rails test` is reliable locally while CI keeps the parallel speedup.
>
> **`PARALLEL_WORKERS` no longer overrides that locally — it is CLAMPED to 1, loudly**
> (`gate-submit-on-green-ci`'s sibling, `/tasks/measure-local-parallel-workers`,
> 2026-08-18). It used to be honoured, which meant asking for 4 workers got you four
> Ruby crash reports and orphan workers holding the test DB, wedging the NEXT run in
> test-prepare on `PG::ObjectInUse`. Now it prints why and runs serially. MEASURED, so
> nobody has to re-litigate it: the FULL suite at 4 workers segfaulted at
> `pg/connection.rb:944` before any test ran, 2 of 2 trials — while `test/models` ALONE
> at 4 workers was clean, 2 of 2. **A partial run is the shape that HIDES this**; re-test
> with the whole suite or you will green-light a default that crashes.
>
> `PARALLEL_WORKERS_ALLOW_UNSAFE=1` restores the requested count. It exists for ONE
> purpose — re-running that measurement after a Ruby, `pg`, or macOS bump. It is not a
> performance switch. If it stops crashing, change the DEFAULT on the evidence and delete
> the clamp; do not leave the hatch as the way in.
>
> If you ever guard something like this: clamping the returned worker count is NOT enough.
> Rails' `parallelize` re-reads `ENV["PARALLEL_WORKERS"]` and that read WINS — it is the
> first branch of its `case`, ahead of the `workers:` argument. The first cut printed its
> warning and forked anyway, with every unit test green, because the tests exercised the
> function in isolation and could not see Rails' precedence. `bin/agent-worktree test <app> <slug>` also runs single-process
> **and clears orphaned `rails test` procs first** — a killed/hung run leaves
> workers holding the test DB and deadlocks the next run. Don't pipe a run through
> `| tail` (it buffers to EOF, so a hang looks identical to "working") — write to a
> logfile. **Never `pkill -f "rails test"`**: with several agents building at once
> that reaps a SIBLING worktree's cert mid-run. Kill by pid, or let the cert's own
> orphan guard do it (below) — it is scoped to one worktree.

### The cert's orphan guard (the timeout-orphan)

A cert can outlive its harness. `bin/fast-check` on a diff that maps to ~120 test
files runs 7+ minutes — well past an agent harness's 120s Bash timeout. When that
timeout killed the cert **parent**, the `bin/rails test` **grandchild survived it**,
reparented to launchd (`PPID 1`), still holding an open connection to the worktree's
test DB:

```
PID   PPID  PGID  STAT COMMAND
41578    1  41538  R   ruby bin/rails test test/models/task_test.rb ...
pg_stat_activity: pid 41763 | idle in transaction | bin/rails
```

Every retry then died in the test-prepare lane — `db:test:purge` cannot DROP a
database another session holds:

```
PG::ObjectInUse: ERROR: database "..._test_..." is being accessed by other users
DETAIL: There is 1 other session using the database.
Tasks: TOP => db:test:load_schema => db:test:purge
```

…and the cert reported that as *"USUALLY an ENV gap … NOT a regression in your
diff"*, never **naming** the orphan. So the agent retried into the same wall: three
attempts, 35 minutes, zero board progress (live, 2026-07-13) — while its ClaimLease
heartbeat kept the task looking healthy on the board. Both cert lanes now defend
against this (`bin/lib/cert_process.rb`, `bin/lib/cert_orphan_guard.rb`):

- **Prevent** — each lane runs in its **own process group**, and the cert reaps that
  GROUP on any signal it can catch (TERM/INT/HUP) or on an exception. The suite can
  no longer outlive the cert that spawned it.
- **Detect** — a SIGKILL runs no handler, so prevention can never be complete. Each
  lane writes a runlock naming its process group **and the OS's start time for it** —
  in the repo's **git dir** (`<git-dir>/cert-run.json`; per-worktree, and invisible to
  `git status` in every repo, because a lock that must survive a SIGKILL would otherwise
  be untracked dirt and the cert refuses a dirty tree). The **next** cert reads it and,
  before any lane runs:
  - cert pid **alive and provably ours** → a real concurrent cert in this tree →
    **refuse** (never kill a live sibling; two suites on one worktree test DB corrupt
    each other's fixtures and SIGSEGV Ruby),
  - cert pid dead, group leader **alive and provably ours** → our own orphan →
    **reap the group, loudly**,
  - something alive under that pgid that is **provably NOT ours** → the OS recycled
    the number → **never kill it**; the lock is a corpse, so discard it and carry on,
  - something alive whose ownership we **cannot prove** (a lock predating this guard) →
    **refuse and name it**, and let a human decide,
  - any **other** session holding the test DB (a pre-fix orphan, a stray manual run,
    a `bin/release` gate suite) → **refuse and name it**, with the
    `pg_terminate_backend` command that clears it.

**A pgid is a recyclable integer — liveness is never identity.** The first cut of this
guard reaped on the predicate *"some process with this pgid is alive"*, and the runlock
is repo-relative (it outlives reboots), so a nine-day-old lock whose pgid the OS had
since handed to an unrelated process made the guard **kill an innocent bystander** and
report "ORPHAN REAPED" (caught in review, 2026-07-14). Identity is therefore the OS's
own start-time record (`ps -o lstart=`) for the pid — recorded at spawn, re-read and
matched exactly before any signal. The rule is: **kill only what you can prove is
yours; if you cannot prove it, refuse and say so.** A reaper that guesses is worse than
no reaper — it turns a stalled cert into a corrupted machine. (And a signal is never
aimed at pgid 0, 1, or the cert's own group: `kill(sig, -1)` means *every process you
own*, not "group 1".)

Every one of those messages says **"NOT a regression in your diff"**, because that is
what an ENV-class failure is. A cert that refuses and names the orphan is a good cert;
a cert that blames "an ENV gap" and lets you retry into a wall is the bug; a cert that
kills a process it cannot name is worse than either.

Skip the guard only in harness tests: `FAST_CHECK_SKIP_ORPHAN_GUARD=1` /
`FULL_SUITE_SKIP_ORPHAN_GUARD=1`.

## Turf Monster

```bash
bin/rails test
npm test
npm run test:parallel
```

Devnet and mainnet-adjacent flows require the app-specific runbooks in `turf-monster/e2e/DEVNET_RUNBOOK.md`, `turf-monster/docs/SOLANA.md`, and `turf-vault/docs/MAINNET_LAUNCH.md`.

## Gems And Contract

Run library tests in their owning repos when changing shared code:

```bash
cd /Users/alex/projects/solana-studio
ruby -Itest -e 'Dir["test/*_test.rb"].sort.each { |f| require File.expand_path(f) }'
```

`studio-engine` is usually verified through the consuming Rails apps.

### The consumer lane checks the hub out under a DIFFERENT DIRECTORY NAME

Hub code can be green in the hub's own CI and red only in `consumer-ci.yml`,
because the two lanes lay the checkout out differently. `consumer-ci.yml` checks
each consumer out at `path: ${{ matrix.consumer }}`, and that matrix value is the
**underscored** label, while the registry name is **hyphenated**:

| Registry repo (`config/release_repos.yml`) | consumer-lane directory |
|--------------------------------------------|-------------------------|
| `mcritchie-studio` | `mcritchie_studio` |
| `turf-monster` | `turf_monster` |
| `mcritchie-industries` | `mcritchie_industries` |

In the projects-root layout those are the same directory, so **no local run and no
hub CI run distinguishes them**. Any hub tool that derives a directory from a repo
NAME therefore has a path bug that only the consumer lane can see. That is how
`bin/release`'s `repo_path` shipped pointing at a `mcritchie-studio` that does not
exist there — `bin/archive-docs --repo=` got the miss and `git -C` raised
`DocsArchive::CommandFailed`, reddening three `test/lib/release_cli_test.rb`
archive tests and stopping a release.

Two rules follow:

- **Resolve the checkout; never name it.** `bin/release`'s `repo_path` goes through
  `RepoCheckout.resolve` (`bin/lib/repo_checkout.rb`), which tries the canonical
  spelling first, falls back to the underscored one, and returns the canonical name
  when neither is on disk — so an absent sibling keeps its current path and its
  current error.
- **Test in the layout CI uses, not the one you have.** A regression test written in
  the projects-root layout proves nothing about this class of bug.
  `test/lib/release_consumer_checkout_test.rb` builds a real git checkout under the
  underscored name and drives the real `bin/release archive` at it.

Note also that in the consumer lane the checkout is dirty by construction — the
lane rewrites `Gemfile` and `config/master.key` — so `Release::ArtifactCommit`
refuses the artifact commit there and `bin/release archive` never flips a git ref
under the running suite.
