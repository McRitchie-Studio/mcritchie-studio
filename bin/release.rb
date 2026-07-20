#!/usr/bin/env ruby
# frozen_string_literal: true

# bin/release — deterministic Deploy-workflow CLI for the McRitchie Studio
# release pipeline. Encodes what used to be hand-run `heroku run rails runner`
# one-liners + ad-hoc git, so the "Prepare release" and "Run Deployment" kickoff
# commands run the same way no matter who (or which agent) runs them.
#
# The record lifecycle lives in the tested Release::Conductor; this CLI owns the
# git + deploy mechanics around it and stops for human judgment on a merge
# conflict (it never auto-resolves).
#
# The integration branch is PERSISTENT: every repo keeps a single `release`
# branch that feature PRs merge INTO. The souls BOOKEND the pipeline (2026-07-03):
# Avi reviews (review-only, stops at `reviewed`) and ships; STEFFON owns the whole
# middle — his self-healing `prepare` SWEEPS the reviewed queue (+ any assembled
# stragglers) onto the candidate, merges their PRs into `release`, deploys QA,
# and flips members `reviewed → assembled` ONLY on QA-green. The task's `merged`
# column ("release"/"main"/nil) is the git-location crash-recovery signal: an
# interrupted Steffon run skips re-merging a `merged: release` task; an
# interrupted Avi run skips re-ff'ing a `merged: main` one.
#
# Usage:
#   bin/release init [--dry-run]
#     One-time (idempotent) per repo: create the persistent `release` branch from
#     `origin/main` in every gem + app repo that doesn't already have one.
#
#   bin/release merge <task-slug> [<task-slug> ...] [--override] [--prod] [--dry-run]
#     The SWEEP primitive (prepare runs this same sweep for the whole queue).
#     ACCEPTED-LADDER SEMANTIC NARROWING: review already merged each feat PR into
#     `accepted`, so `merge <slug>` no longer touches the named task's feat PR — it
#     PROMOTES all of `accepted` onto `release` (ONE batch PR per repo,
#     promote_accepted_to_release!) and records the NAMED slugs' membership in a
#     SINGLE `heroku run` (membership + merged:"release"; the STAGE stays `reviewed`
#     — it flips to `assembled` only on prepare's QA-green). It therefore lands
#     EVERY reviewed change on `accepted`, not just the named one — use it to force
#     a specific reviewed task onto the RC ahead of the sweep. A named task with no
#     code on `accepted` (merged:"") ABORTS (review must land its PR first); a task
#     already `merged: release/main` skips the promote (crash recovery) but still
#     records. Promote is idempotent + fail-closed (accepted level with release →
#     skip the PR, still record).
#     REVIEW-GATE GUARD: before the promote, every requested task must be sweepable
#     (`reviewed`, or an `assembled` straggler) — anything else ABORTS the whole run
#     (naming which task is in which stage). `--override` is the explicit escape
#     hatch: it sweeps the task anyway AND records a `review_bypassed` event on the
#     task's audit spine (the same spine `bin/task move` writes) — never silent.
#
#   bin/release prepare [--task SLUG ...] [--slug rel-YYYY-MM-DD-name] [--prod] [--dry-run]
#     Steffon's SELF-HEALING qa-deploy — the whole middle of the pipeline:
#       1. DETECT the work: every `reviewed` task + any `assembled` straggler not
#          riding the current RC (nothing + no active release → idempotent no-op).
#       2. Ensure a candidate exists (Release.current_or_open!).
#       3. PROMOTE + RECORD: review already merged each feat PR into `accepted`, so
#          the sweep PROMOTES all of `accepted` onto `release` via ONE batch PR per
#          repo (promote_accepted_to_release!; a `reviewed` member with no code on
#          `accepted` is a HELD anomaly, warned + left behind), then records
#          membership + merged:"release" in ONE `heroku run`. Stages stay `reviewed`.
#       4. GEM MEMBERS (publish-gems-before-qa) — two phases, because a RubyGems
#          push is irreversible: preflight EVERY swept gem (fail-closed fetch,
#          version bumped, stranded-work guard, a swept consumer declares it;
#          ANY failure aborts with ZERO gems published), THEN publish each to
#          RubyGems + commit each consumer's lock bump onto origin/release —
#          BEFORE the gate and QA (ship's publish stays the idempotent verify).
#       5. PRE-QA GATE: run each app's registry `qa_test_cmd` (the integration +
#          e2e-smoke tier) on origin/release BEFORE deploying; a regression aborts
#          with eject guidance (`bin/release eject` the offender, keep the rest).
#       6. Deploy origin/release to QA (merge-forward guard → qa-server deploy →
#          wait-for-boot /up smoke → post_deploy hooks).
#       7. QA-GREEN → flip the swept members `reviewed → assembled`
#          (Release::Conductor.qa_green!; merged stays "release") + assemble the
#          RC. A QA failure leaves them `reviewed` — the next run self-heals.
#     `--task` narrows the sweep to the named slugs (operator curation).
#
#   bin/release eject <task-slug> [--feedback "…"] [--prod] [--dry-run]
#     BLOCK-ON-REGRESSION: pull ONE offending task off the candidate (the pre-QA
#     gate caught it) — detaches it (release_slug + merged cleared) and blocks it
#     for rework with the feedback note, leaving the REST of the RC riding. Then
#     revert its merge commit on `release` (printed guidance) and re-run
#     `bin/release prepare`.
#
#   bin/release ship [--by NAME] [--prod] [--dry-run]
#     Avi's production-deploy: promotes the QA-green (assembled) RC to production:
#     ff main → release branch per repo, push origin (stamping each repo's members
#     `merged: "main"` — assembled+main = prod-in-flight), deploy to Heroku, smoke
#     /up, run any member's post_deploy_cmd on the PROD app (aborts on non-zero),
#     stamp deployed_sha + flip to shipped (shipped+main = done).
#
#   bin/release archive [--prod] [--dry-run] [--yes]
#     The DevOps loop's CONCLUSION (shipped → archived): archive every shipped
#     task that ISN'T a member of the last shipped release (those members stay
#     `shipped` as the board's read-only "Last Release"), then reclaim the
#     merged/shipped feature worktrees. Idempotent — a re-run archives nothing
#     new and reclaims nothing left. --dry-run previews the archivable plan + the
#     worktree-reclaim list (the reclaim tool's own dry-run), mutating nothing.
#
#   bin/release retro [release-slug] [--worked "…"] [--friction "…"] [--followup "…"]
#                     [--file-tasks] [--yes] [--dry-run]
#     The post-ship "review & learn" step — completely NON-BLOCKING (archive does
#     not depend on it). Defaults to the current/most-recently-shipped release.
#     AUTO-GATHERS the release record (members + kinds, per-member submitted→shipped
#     cycle timing from TaskEvents, rework rounds, reviewers, recorded checks_run)
#     and PROMPTS a few judgment questions (what worked / what caused friction /
#     follow-ups). --worked/--friction/--followup (repeatable) supply answers from
#     args; --yes runs fully non-interactive (no TTY). WRITES a durable doc at
#     docs/agents/audits/retro-<slug>.md. --file-tasks files each follow-up via
#     `bin/task create`. Writes NO agent-memory store — the doc (+ tasks) is the
#     record. --dry-run previews the gathered record + doc path, writing nothing.
#
# Targets:
#   default        record ops run on PRODUCTION via `heroku run rails runner`
#                  (the board IS production). On a non-dry run `prepare` also fires
#                  a REAL `bin/qa-server deploy` and `ship` a REAL prod deploy —
#                  use --dry-run to preview safely.
#   --local        the OLD behavior: record ops run against the local db. That db
#                  is stale, so the board won't reflect production — dev/testing
#                  only.
#   --prod         accepted but a no-op (production is now the default).
#   --dry-run      print the plan; execute nothing
#
# The board is production, so record ops default to production. Git push to
# `heroku` always deploys prod (that IS the deploy), so `ship` asks to confirm
# first.

require "json"
require "base64"
require "open3"
require "yaml"
require "tmpdir"
require "shellwords"
require "fileutils" # primary_checkout_lock_path mkdir_p's the fixed lock dir

# Pure release DECISION logic (adapter dispatch, hub-first ordering, gem
# publish/repin) lives in the unit-tested Release::ShipSequence +
# Release::GemfileRepin models so this CLI stays I/O-only. Both files are
# dependency-free Ruby (no Rails), so they load standalone here — keeping the
# string/version/ordering decisions in one tested place instead of mirrored in
# the shell. GemfileRepin first: ShipSequence references it at call time.
# Release::Cli holds the pure ARGV-parsing helpers (also Rails-free) the flag
# handling below routes through.
require_relative "../app/models/release/gemfile_repin"
require_relative "../app/models/release/ship_sequence"
require_relative "../app/models/release/post_deploy"
require_relative "../app/models/release/merge_plan"
# SweepPlan is the pure per-task sweep partition (record onto the RC / held anomaly)
# behind prepare's self-healing sweep + merge, plus the batch-PR base assertion.
# Rails-free.
require_relative "../app/models/release/sweep_plan"
require_relative "../app/models/release/artifact_commit"
require_relative "../app/models/release/cli"
# CleanCheck is the pure verdict behind the `deploy-with-task` clean-release GUARD
# (`bin/release status --clean-only`): given the pending assembled tasks (board)
# and the per-repo release-ahead-of-main counts (git), it decides clean vs dirty
# and builds the refusal + `full-cycle` offer. Rails-free → unit-tested.
require_relative "../app/models/release/clean_check"
# SmokeSeal builds the post-ship 🟢/🔴 verdict + the EXACT rollback guidance the
# red-seal alert prints (step 5c). Rails-free, so the alert comes from the SAME
# source the notes/board read on prod.
require_relative "../app/models/release/smoke_seal"
# ProdSmoke resolves the prod base URL for the seal smoke (bin/prod-smoke shares it).
require_relative "../app/models/release/prod_smoke"
# SealRetry is the seal's ONE caller-side boot-window retry (step 5c): first
# failure waits ~30s, retries once; only a persisting failure seals red.
# Caller-side so bin/prod-smoke stays single-shot. Rails-free → unit-tested.
require_relative "../app/models/release/seal_retry"
# SealRun composes that retry with SmokeSeal into the recorded verdict (+ the
# summary's retry note), so step 5c's behavior is testable on real objects.
require_relative "../app/models/release/seal_run"
# GateRuby pins the LOCAL pre-QA / ship test gates to CI's ruby (mise 3.3.11) so a
# gate host whose shell `ruby` is brew's ruby@3.3 doesn't diverge from CI — the
# gate suite (and the bin/release / bin/dor-check subprocesses its meta-tests
# spawn) runs with mise's ruby bin dir leading PATH, so `env ruby` == CI's ruby.
# Rails-free → unit + integration tested.
require_relative "../app/models/release/gate_ruby"
require_relative "../app/models/release/gate_env"
require_relative "../app/models/release/gate_workspace"
# Deploy-side usage capture: read the conductor's LOCAL session transcript and
# diff it against the per-(session, slug) baseline (shared verbatim with bin/task
# + bin/reviewer-select) so reviewed→assembled / assembled→shipped flips carry
# the model/token/cost the agent actually burned. Plain Ruby (no Rails).
require_relative "../lib/agent_session_usage"
require_relative "../lib/task_usage_baseline"
require_relative "../lib/task_usage_sandbox"
require_relative "lib/session_identity"
# GitHub CI's verdict for a COMMIT — the same source bin/dor-check reads for a PR,
# asked about the release-tip SHA the pre-QA/ship gate certifies (CiStatus.for_sha).
# Since DevOps v2 Phase 3 CI IS the G3/G4 verdict (ci_pass?), not a cross-check.
require_relative "lib/ci_status"

APP = "mcritchie-studio"
HEROKU_REMOTE = "heroku"

# The self-narration CLI this deploy lane opens+closes role activities through.
# Same bin the session narrates with — which the capture hook drops from raw
# actions, so only the resulting activity shows on the heartbeat.
AGENT_ACTIVITY = File.expand_path("agent-activity", __dir__)

# The persistent per-repo integration branch (same name in every repo). Mirrors
# Release::BRANCH on the record side — feature PRs merge into it, QA deploys from
# it, ship fast-forwards it into main.
RELEASE_BRANCH = "release"

# The accepted-ladder's first rung (same name in every repo). Review MERGES each
# feat PR into `accepted` and stamps merged:"accepted"; the sweep then promotes ALL
# of `accepted` onto `release` via ONE batch PR per repo (promote_accepted_to_release!
# uses this as the `--head`). KEPT — the batch PR's head needs the branch name.
# (Phase 3 Slice 4 retired the release→accepted base-retarget stopgap that used to
# live here; Phase 4 deleted its last remnant.)
ACCEPTED_BRANCH = "accepted"

# The producer/consumer repo registry (config/release_repos.yml) — tells the CLI
# which members are gems (published producer-first, no app branch) vs apps. Same
# single source of truth Release::Repos reads on the record side.
RELEASE_REPOS =
  begin
    YAML.load_file(File.expand_path("../config/release_repos.yml", __dir__)) || {}
  rescue StandardError
    {}
  end

# Every ecosystem repo — gems, apps, AND this hub — is checked out as a SIBLING
# at the projects root. `repo_path` resolves that sibling path .worktrees-aware,
# so paths resolve whether bin/release runs from a primary checkout
# (…/projects/mcritchie-studio/bin) or (defensively) a worktree
# (…/projects/mcritchie-studio/.worktrees/<wt>/bin). Mirrors bin/qa-server's
# default_projects_dir, which climbs out of .worktrees to the real projects root.
#
# `projects_root` is pure given its app_root argument (so it's unit-testable for
# both checkout shapes); it defaults to this script's own app root. A PROJECTS_DIR
# env override wins (mirrors bin/qa-server) so a non-default checkout layout can
# point the sibling-repo resolution at the right root.
def projects_root(app_root = File.expand_path("..", __dir__))
  return File.expand_path(ENV["PROJECTS_DIR"]) if ENV["PROJECTS_DIR"].to_s != ""

  parent = File.expand_path("..", app_root)
  # A worktree's app root sits under <hub>/.worktrees/<wt>; climb out of
  # .worktrees/<wt> back to the real projects root that holds the siblings.
  return File.expand_path("../..", parent) if File.basename(parent) == ".worktrees"

  parent
end

# The sibling checkout path for any ecosystem repo (a gem, an app, or the hub).
def repo_path(repo)
  File.join(projects_root, repo.to_s)
end

# Every registered ecosystem repo — gems AND apps — from the release registry.
# The set `init` seeds the persistent `release` branch in.
def release_repo_slugs
  (RELEASE_REPOS.fetch("gems", {}).keys + RELEASE_REPOS.fetch("apps", {}).keys)
end

# A gem's declared version, read locally from its version_file. The authoritative
# read at publish time (member_plan's version can be nil when run via `--prod`,
# where the sibling repo isn't checked out). Returns "" if it can't be resolved.
def gem_version_local(repo)
  meta = RELEASE_REPOS.dig("gems", repo) || {}
  version_file = meta["version_file"].to_s
  return "" if version_file.empty?

  path = File.join(repo_path(repo), version_file)
  return "" unless File.exist?(path)

  File.read(path)[/version\s*=\s*["']([\w.\-]+)["']/i, 1].to_s
end

# URLs come from the QA registry (config/qa_environments.yml) — single source of
# truth, so the CLI doesn't drift from the deploy config. Load the FULL map so
# the per-repo prepare loop can report each app's QA review URL (keyed by the
# qa-server app), not just the hub's.
QA_ENVIRONMENTS =
  begin
    YAML.load_file(File.expand_path("../config/qa_environments.yml", __dir__))
        .fetch("qa_environments", {})
  rescue StandardError
    {}
  end
QA_REGISTRY = QA_ENVIRONMENTS[APP] || {}
PROD_URL = QA_REGISTRY["production_url"] || "https://mcritchie.studio"

# The QA review URL for a qa-server app key (the group's `qa_app`). "" when the
# app isn't registered — the summary just omits a link and falls back to the key.
def qa_url_for(app)
  (QA_ENVIRONMENTS[app] || {})["qa_url"].to_s
end

# Whether an app is registered in config/qa_environments.yml — i.e. has a QA
# target to deploy to. A repo can be a registered app in release_repos.yml yet
# have NO QA env (tax-studio, chain-ops); prepare warns + skips its QA deploy
# rather than aborting the whole release. (validate_members! already aborts on a
# fully-unknown repo; this is the softer "registered app, no QA env" case.)
def qa_registered?(app)
  QA_ENVIRONMENTS.key?(app.to_s)
end

DRY = Release::Cli.take_flag(ARGV, "--dry-run")
# Production is the DEFAULT target now (the board IS production) — pass --local to
# opt into the old, stale-local-db behavior. `--prod` is still consumed so the old
# flag stays a harmless no-op.
Release::Cli.take_flag(ARGV, "--prod")
PROD = !Release::Cli.take_flag(ARGV, "--local")
ASSUME_YES = Release::Cli.take_flag(ARGV, "--yes")
# The FIRST-CLASS override for a ship test gate the operator believes is a false
# negative. It replaces the old registry-blanking trick, which silently DISARMED
# the gate; this one demands `--reason`, confirms, and records a RED gate SOP. See
# test_gate.
SKIP_TEST_GATE = Release::Cli.take_flag(ARGV, "--skip-test-gate")

def abort!(msg) = abort("✗ #{msg}")
def say(msg) = puts(msg)

# A discrete deploy operation: printed to the release log AND — inside a role span
# (prepare/ship) — self-reported as ONE AgentAction so the Remote deploy span shows
# genuine rows. bin/release's real work runs as SUBPROCESSES of a single Bash tool
# call, invisible to the PostToolUse capture hook, so without this the span reads
# "No raw actions attributed". Gated on $role_span_open so steps OUTSIDE a span
# (status/merge reads) don't spawn a report with nothing to attribute to.
def step(msg)
  puts("→ #{msg}")
  agent_action(msg) if $role_span_open
end

# Loud banner printed at the top of prepare/ship when --local opted out of the
# production board. The local db is stale, so a release run against it won't
# reflect production — only useful for dev/testing.
def warn_local!
  return if PROD

  say("⚠ --local: record ops run against the STALE local DB — the board won't reflect production; use the default for real releases.")
end

# Run a shell command. In dry-run, print it and skip. `chdir:` runs it in
# another directory (used for gem-repo builds/tags). `env:` is an optional
# environment overlay merged into the child — the gates pass it so the spawned
# suite/bundle/probe resolve `env ruby` to mise, see NO agent session, and boot
# against the gate's private test DB (see gate_env / Release::GateEnv). A nil
# VALUE in that overlay UNSETS the key in the child (Process.spawn semantics) —
# that is how the session scrub reaches every grandchild the suite spawns. A
# blank/nil overlay leaves the argv exactly as-is. Returns [stdout, ok?].
def sh(*cmd, capture: false, chdir: nil, env: nil)
  printable = "#{chdir ? "(cd #{chdir}) " : ''}#{cmd.join(' ')}"
  if DRY
    puts "  [dry-run] #{printable}"
    return ["", true]
  end
  opts = chdir ? { chdir: chdir } : {}
  # A leading env Hash sets the child's environment WITHOUT touching argv, so a
  # command stub keying on argv[0] still matches (env lands in the trailing opts).
  argv = env && !env.empty? ? [env, *cmd] : cmd
  if capture
    out, status = Open3.capture2e(*argv, opts)
    [out, status.success?]
  else
    ok = system(*argv, opts)
    ["", ok]
  end
end

# Dispatch a GitHub Actions workflow (`gh workflow run`) and WATCH it to
# completion; returns true iff the run concluded SUCCESSFULLY. The DevOps v2
# Phase-2 deploy mechanic for the hub: prepare fires qa-deploy.yml, ship fires
# prod-deploy.yml. The `production` Environment's required reviewer means the
# prod run PAUSES for the operator's approval mid-watch — that pause IS the
# ship-confirm gate (it replaced the local interactive prompt), so the watch is
# expected to block until the operator clicks. DRY short-circuits before any `gh`.
#
# FINDING THE RUN ID is the one subtlety. `gh workflow run` prints nothing that
# identifies the run it created, and `gh run list --limit 1` alone is a trap: a
# PRIOR concluded run of the same workflow (prod deploys repeat, so one usually
# exists) is the newest until ours registers, and watching THAT would read a
# stale verdict → a false-green deploy. GitHub run ids increase monotonically, so
# we snapshot the newest id BEFORE dispatch and poll (the run takes a couple
# seconds to register) until a run with a STRICTLY GREATER id appears — that run
# is unambiguously ours (Release::ShipSequence.new_run_id owns that pure choice).
#
# FAILS CLOSED on a gh that won't answer. newest_run_id returns nil on a `gh run
# list` FAILURE (distinct from 0 = "no runs exist yet"): a transient failure of
# the PRE-dispatch snapshot must NOT read as before_id=0, or the poll could latch
# a pre-existing run. So we retry the snapshot, ABORT if it never answers, and in
# the poll SKIP a nil read rather than compare it.
def dispatch_and_watch(workflow, inputs = {}, chdir: nil)
  return true if DRY

  before_id = nil
  5.times do
    before_id = newest_run_id(workflow, chdir: chdir)
    break unless before_id.nil?

    sleep 3
  end
  return false if before_id.nil? # gh never answered — do not watch a stale run

  args = ["gh", "workflow", "run", workflow]
  inputs.each { |k, v| args += ["-f", "#{k}=#{v}"] }
  _, dispatched = sh(*args, chdir: chdir)
  return false unless dispatched

  run_id = nil
  20.times do
    # nil (a transient list failure) is SKIPPED, never compared to before_id.
    run_id = Release::ShipSequence.new_run_id(before_id, newest_run_id(workflow, chdir: chdir))
    break if run_id

    sleep 3
  end
  return false unless run_id

  _, watched = sh("gh", "run", "watch", run_id.to_s, "--exit-status", chdir: chdir)
  return true if watched

  # Don't trust the WATCH's exit alone. Seen LIVE (Phase 2 validation, run
  # 29440752482): a transient GitHub HTTP 500 killed `gh run watch` mid-watch while
  # the run itself SUCCEEDED (prod deployed, /up 200). Returning the watch's exit
  # would then ABORT a ship that actually shipped — an operator-facing false
  # negative. So a failed watch is not a verdict: re-query the run's REAL
  # conclusion and let THAT decide (fails closed if the run genuinely failed or
  # becomes unobservable).
  say("  ⚠ `gh run watch` exited non-zero for run #{run_id} — re-querying the run's real conclusion (a transient watcher failure is not a failed deploy)")
  run_concluded_success?(run_id, chdir: chdir)
end

# The run's REAL conclusion, straight from GitHub, for when `gh run watch` could
# not report it (a transient watcher failure — an HTTP 500 mid-watch — must never
# be read as a failed deploy). MIRRORS `gh run watch`: it FOLLOWS the run to its
# GitHub-side conclusion, however long that takes, on `gh run view --json
# status,conclusion`, and lets Release::ShipSequence.run_watch_verdict decide each
# read (:success / :failed / :pending — pure, unit-tested).
#
# WHY IT IS NOT A SHORT WALL-CLOCK BUDGET (the bug this closes, run 29450907913):
# a prod-deploy run PAUSES at the `production` Environment's required reviewer,
# reporting `waiting` for as long as the operator takes to click (3h34m live). The
# old fallback polled only 20×5s=100s for `completed` and failed the ship CLOSED
# over a deploy that had simply not been approved yet. A `waiting`/`queued`/
# `in_progress` run is LIVE — reading any live status is affirmative proof the run
# is alive, so the watcher HOLDS on it (unbounded, exactly as `gh run watch`
# would; GitHub's own job timeout concludes a truly hung run).
#
# FAILS CLOSED on exactly two things — a redundant re-verify beats a false green:
#   * a TERMINAL non-success (:failed) → promptly, over one poll.
#   * an UNOBSERVABLE run — `gh run view` erroring or returning no status for
#     `unreadable_limit` CONSECUTIVE polls (a genuine stuck-timeout with no state
#     progress: the "never-appearing" run). A single successful live read resets
#     the streak, so an approval pause of any length never trips it.
def run_concluded_success?(run_id, chdir: nil, poll: 10, unreadable_limit: 30)
  unreadable = 0
  last_status = nil
  loop do
    out, ok = sh("gh", "run", "view", run_id.to_s, "--json", "status,conclusion",
                 "--jq", "[.status, .conclusion] | @tsv", chdir: chdir, capture: true)
    status, conclusion = ok ? out.strip.split("\t", 2) : [nil, nil]

    # A read we could not make (gh errored) OR that returned no status is an
    # UNOBSERVED poll — it counts toward the stuck-timeout, never toward a verdict.
    if status.to_s.strip.empty?
      unreadable += 1
      if unreadable >= unreadable_limit
        say("  ⚠ run #{run_id} unobservable for #{unreadable} consecutive polls — failing closed")
        return false
      end
      sleep poll
      next
    end
    unreadable = 0

    case Release::ShipSequence.run_watch_verdict(status, conclusion)
    when :success
      say("  run #{run_id} concluded: success")
      return true
    when :failed
      say("  run #{run_id} concluded: #{conclusion} — failing closed")
      return false
    else # :pending — the run is still live; hold, exactly as `gh run watch` would
      if status != last_status
        note = Release::ShipSequence.approval_pause?(status) ?
                 "WAITING for the production approval — holding (an approval pause is not a failure)" :
                 "#{status} — holding"
        say("  run #{run_id} #{note}")
      end
    end

    last_status = status
    sleep poll
  end
end

# The newest GitHub Actions run id for `workflow` — 0 when none exists yet, or
# nil when `gh run list` FAILED. The nil-vs-0 distinction is load-bearing (see
# dispatch_and_watch): a caller must not read a transient failure as "no runs".
# jq `// empty` yields "" on an empty list, which `to_i` maps to the genuine 0.
def newest_run_id(workflow, chdir: nil)
  out, ok = sh("gh", "run", "list", "--workflow", workflow, "--limit", "1",
               "--json", "databaseId", "--jq", ".[0].databaseId // empty",
               chdir: chdir, capture: true)
  return nil unless ok

  out.strip.to_i
end

# The SHELL-SAFE `rails runner` payload for a conductor snippet. The snippet is
# wrapped (`require 'json'`), Base64-encoded, and shipped as
# `eval(Base64.urlsafe_decode64("<blob>"))` — so the command line carries ONLY a
# url-safe Base64 literal (alphabet [A-Za-z0-9_-]=, zero shell metacharacters,
# zero nested/escaped quotes) the remote runner decodes + evals.
#
# This closes the paren/quote ship-blocker at the SHARED seam, so EVERY conductor
# caller is shell-safe: record_post_deploy_check interpolated `cmd.inspect` into
# the snippet, and a seed-54-style post_deploy_cmd
# (`bin/rails runner "load Rails.root.join(%q(...)).to_s"`) arrived as escaped
# quotes + parens. `heroku run` re-quotes its remote command, and that re-quoting
# ATE the \"-escaping — exposing the `(` as a remote `bash: syntax error near
# unexpected token '('`, which made `conductor` hit abort! ("record op returned
# no JSON") and aborted prepare BEFORE assemble! (and would abort ship after the
# prod-deploy + gem-publish). The Base64 bootstrap is structurally identical to
# the proven-safe `Base64.urlsafe_decode64("…")` literal retro_record_ruby
# already rides through `heroku run`. Pure (no Rails) → unit-tested standalone.
def conductor_payload(ruby)
  wrapper = "require 'json'; #{ruby}"
  blob = Base64.urlsafe_encode64(wrapper)
  "eval(Base64.urlsafe_decode64(#{blob.inspect}))"
end

# This conductor's local SESSION id (Claude or Codex), or nil. Used to tag the
# deployment with the agent working it — see with_conductor_session.
def conductor_session_id
  conductor_session_identity.first
end

def conductor_session_identity
  id, provider = SessionIdentity.identity
  [id, provider || "claude"]
end

# Prefix a conductor snippet with the local session id so the prod `rails runner`
# can stamp the deployment's Pokémon mascot (Release stamps the SESSION's mascot —
# the agent running bin/release). The session lives in THIS shell's env, which does
# NOT cross the `heroku run` boundary, so we pass it in-band. `Current.try(:…=)` so
# an older prod that predates the attribute ignores it instead of erroring mid-ship
# — the stamp is best-effort, never load-bearing for a release op. A session-less
# run (no env var) returns the snippet untouched. Pure → unit-tested standalone.
def with_conductor_session(ruby)
  sid = conductor_session_id
  return ruby unless sid

  "Current.try(:conductor_session_id=, #{sid.inspect}); #{ruby}"
end

# --- deploy-lane self-narration (best-effort) -------------------------------
# Open+close an AgentActivity around a release phase, stamped with the ROLE
# soul the board already attributes that phase to — Steffon assembles (prepare),
# Avi ships — so the heartbeat's deploy activities match the board's stage timeline.
# Narrated through bin/agent-activity (the SAME path the session narrates with,
# which the capture hook DROPS from raw actions, so only the resulting activity
# shows). BEST-EFFORT + NON-FATAL: telemetry must never break a release, so a
# missing bin, a down endpoint, or any error is swallowed. Skipped under
# --dry-run (a preview narrates nothing) and when no conductor session is
# resolvable (nothing to attribute the activity to).

# True while bin/release holds an OPEN role span (open_role_span … close_role_span),
# so step() knows to self-report its actions into it. Off-span steps skip the
# report — there's no span to attribute them to.
$role_span_open = false

# Fire one bin/agent-activity subcommand, best-effort. The command itself always
# exits 0; we still swallow everything and redirect its stdout/stderr so the
# narration never disturbs the release log or aborts the run.
def agent_activity(*args)
  return if DRY
  return unless conductor_session_id # no session → nothing to narrate

  system(AGENT_ACTIVITY, *args, out: File::NULL, err: File::NULL)
rescue StandardError
  nil
end

# Self-report ONE off-box action into the open role span, so the Remote deploy
# span carries real rows for work the PostToolUse hook can't see (git / gh /
# `heroku run` all run as subprocesses of ONE Bash tool call). Thin shell-out to
# the narration CLI's `action` verb — inert under --dry-run and with no conductor
# session (agent_activity guards both), and a no-op when no activity is open (the
# verb self-checks the open-activity marker).
def agent_action(summary, key_method: nil, kind: nil, event_slug: nil, result_slug: nil, duration_ms: nil)
  args = ["action", "--summary", summary.to_s]
  args += ["--key-method", key_method.to_s] if key_method
  # Verdict-only tag fields — a graded test-scope run carries them; a plain step
  # (or a START emit) passes them nil and they never reach the POST body.
  args += ["--kind", kind.to_s] if kind
  args += ["--event-slug", event_slug.to_s] if event_slug
  args += ["--result-slug", result_slug.to_s] if result_slug
  args += ["--duration-ms", duration_ms.to_s] if duration_ms
  agent_activity(*args)
end

def open_role_span(agent, reason)
  $role_span_open = true
  agent_activity("start", "--category", "Remote", "--reason", reason, "--agent", agent)
end

def close_role_span(outcome)
  agent_activity("end", "--outcome", outcome)
  $role_span_open = false
end

# --- test-scope telemetry (best-effort) --------------------------------------
# Every test scope this CLI runs is a logged, GRADEABLE unit: run_test_scope
# emits one START and one COMPLETED/FAILED AgentAction per run through the same
# self-report path step() uses (agent_action → bin/agent-activity action). The
# scope registry (config/devops_test_suites.yml `release_scopes:`) declares each
# scope's stable key + phase/tier/host/blocks metadata. Telemetry is BEST-EFFORT
# + NON-FATAL by the step()/agent_action contract: gated on $role_span_open
# (outside a role span there is no activity to attribute to), inert under
# --dry-run and without a conductor session (agent_activity guards both), and
# any telemetry error is swallowed — only the COMMAND result is load-bearing.
#
# ReleaseEvent channel note: ReleaseEvent::STEPS whitelists step names
# (inclusion validation), so per-scope telemetry deliberately stays on the
# AgentAction channel — inventing new release-event steps would be rejected by
# the model (and pollute the /deployments tracker if whitelisted). The gates'
# existing release-event pairs (ship_gate, qa_smoke, prod_smoke, …) are
# unchanged.

# The release-scope registry: scope key → {phase, tier, host, blocks, mutates}.
# Missing file / malformed YAML degrades to {} — the registry enriches
# telemetry; it must never break the CLI.
TEST_SCOPES =
  begin
    (YAML.load_file(File.expand_path("../config/devops_test_suites.yml", __dir__)) || {})
      .fetch("release_scopes", {})
  rescue StandardError
    {}
  end

def scope_meta(key) = TEST_SCOPES[key.to_s] || {}

# Lenient result-count parsing — nil when nothing recognizable (that's fine;
# the summary just omits counts):
#   minitest    "141 runs, 320 assertions, 0 failures, 0 errors" — SUMMED across
#               summary lines (`rails test test:system` prints one per lane)
#   playwright  "12 passed" (+ "2 failed" when present)
#   /up probe   a bare 3-digit http code body ("200")
def parse_test_counts(out)
  text = out.to_s
  runs = text.scan(/(\d+) runs?, (\d+) assertions?, (\d+) failures?, (\d+) errors?/)
  if runs.any?
    sums = runs.transpose.map { |col| col.sum(&:to_i) }
    return format("%d runs, %d assertions, %d failures, %d errors", *sums)
  end
  if (passed = text[/(\d+) passed/, 1])
    failed = text[/(\d+) failed/, 1]
    return failed ? "#{passed} passed, #{failed} failed" : "#{passed} passed"
  end
  code = text.strip
  return "http #{code}" if code.match?(/\A\d{3}\z/)

  nil
end

# Emit one test-scope AgentAction, best-effort. Keeps step()'s $role_span_open
# gating; any error is swallowed (agent_action already swallows its own — this
# belt-and-suspenders covers the summary plumbing too).
def scope_action(summary, key_method: nil, kind: nil, event_slug: nil, result_slug: nil, duration_ms: nil)
  if $role_span_open
    agent_action(summary, key_method: key_method, kind: kind, event_slug: event_slug,
                 result_slug: result_slug, duration_ms: duration_ms)
  end
rescue StandardError
  nil
end

# Run ONE registered test scope: emit START, run the command via sh() with the
# call site's exact capture:/chdir: (or the given block — wait_for_boot's /up
# poll is one scope but many curls; a block must return [out, ok]), then emit
# COMPLETED/FAILED carrying {scope key, repo/host, pass|fail, counts, duration,
# command}. Returns [out, ok] exactly like sh(), so call sites keep their exact
# abort!/non-blocking behavior. A command that RAISES (Open3 ENOENT etc.) still
# emits the FAILED action, then RE-RAISES — the call site's rescue semantics
# (production_smoke_seal degrades it to a red seal) stay untouched.
#
# The VERDICT emit (COMPLETED/FAILED only — never START) is TAGGED to make the run
# a first-class GRADEABLE unit in /alex/pipeline: kind="test_scope", event_slug=the
# scope key, result_slug=pass|fail, duration_ms=the wall-clock. These ride the same
# best-effort self-report path; a bare START stays untagged so the pipeline's
# `kind:"test_scope" AND result_slug present` filter never surfaces it.
def run_test_scope(key, *cmd, capture: false, chdir: nil, repo: nil, label: nil, env: nil, &block)
  meta  = scope_meta(key)
  where = repo.to_s.empty? ? meta["host"].to_s : repo.to_s
  printable = (label || cmd.join(" ")).to_s
  scope_action("test scope #{key} START · #{where} · #{printable}")
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  begin
    # Pass `env:` to sh ONLY when the caller set an overlay (the gate ruby pin) —
    # non-gate scopes call sh with the exact original keywords, so a strict sh
    # stub (or any caller that predates env:) is untouched.
    kw = { capture: capture, chdir: chdir }
    kw[:env] = env if env && !env.empty?
    out, ok = block ? block.call : sh(*cmd, **kw)
  rescue StandardError => e
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    gate_sop(key, printable, false, (elapsed * 1000).round)
    scope_action("test scope #{key} FAILED · #{where} · fail · #{e.class}: #{e.message} · " \
                 "#{format('%.1fs', elapsed)} · #{printable}", key_method: printable,
                 kind: "test_scope", event_slug: key.to_s, result_slug: "fail",
                 duration_ms: (elapsed * 1000).round)
    raise
  end
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  gate_sop(key, printable, ok, (elapsed * 1000).round)
  begin
    parts = ["test scope #{key} #{ok ? 'COMPLETED' : 'FAILED'}", where, ok ? "pass" : "fail"]
    counts = parse_test_counts(out)
    parts << counts if counts
    parts << format("%.1fs", elapsed)
    parts << printable
    scope_action(parts.join(" · "), key_method: printable,
                 kind: "test_scope", event_slug: key.to_s, result_slug: ok ? "pass" : "fail",
                 duration_ms: (elapsed * 1000).round)
  rescue StandardError
    nil # telemetry never breaks a release — the command result below is what matters
  end
  [out, ok]
end

# Invoke a Release::Conductor snippet — locally, or on prod via `heroku run`.
# The snippet must `puts` a single JSON line; we return the parsed Hash. The
# snippet rides as a shell-safe Base64 bootstrap (see conductor_payload) so any
# quotes/parens/&& in it survive heroku's remote re-quoting intact.
#
# WRITES are suppressed in --dry-run (printed, not run). A read_only: query still
# runs in dry-run — a read mutates nothing, so it honors "execute nothing" while
# letting a dry-run PREVIEW the real plan. read_only goes straight to Open3 so
# it bypasses sh's own dry-run gate.
def conductor(ruby, read_only: false)
  payload = conductor_payload(with_conductor_session(ruby))
  cmd = PROD ? ["heroku", "run", "-a", APP, "--no-tty", "rails", "runner", payload]
             : ["bin/rails", "runner", payload]
  if DRY && !read_only
    puts "  [dry-run] #{PROD ? 'heroku run ' : ''}rails runner: #{ruby}"
    return {}
  end
  out, status = Open3.capture2e(*cmd)
  abort!("record op failed:\n#{out}") unless status.success?
  line = out.lines.reverse.find { |l| l.strip.start_with?("{") }
  abort!("record op returned no JSON:\n#{out}") unless line
  JSON.parse(line)
end

# Record a deploy-lane crew-ticker intent on the board — a COSMETIC write that only
# paints the live /deployments "who's on it now" badge; nothing the deploy depends on.
# So it is BEST-EFFORT: conductor() abort!s (→ SystemExit) on ANY non-zero heroku-run
# exit, and a transient prod-board outage (e.g. the documented 2026-06-25 essential-PG
# "too many connections" incidents) on this cosmetic ticker must WARN and CONTINUE —
# it must NEVER abort a real `prepare`/`ship`. Mirrors bin/reviewer-select's best-effort
# review-intent write (rescue SystemExit, StandardError → warn → continue, ~lines 325-326).
# Scoped narrowly to the intent write ONLY — every deploy-critical conductor() call stays
# FATAL, so real deploy errors still abort.
def record_deploy_intent(label, ruby)
  conductor(ruby)
rescue SystemExit, StandardError => e
  say("  ⚠ #{label} not recorded — crew-ticker board write failed (#{e.message}); deploy continues (cosmetic only)")
end

# --- release-grain gate runs (G3 Candidate / G4 Ship) -----------------------
# Attempt-aware GateRun records for the two release-owned testing gates, written
# through the model's open!/close! funnel via conductor snippets. The window is
# bracketed by record_gate_open/record_gate_close; every test SOP run inside it
# is COLLECTED by the one-line gate_sop hook in run_test_scope (zero extra
# round-trips — the sops ride the close payload). ALL gate writes are
# BEST-EFFORT: a board blip must never abort a prepare/ship (mirrors
# record_release_event), and --dry-run suppresses them via conductor's own gate
# (the plan still prints). $gate_sops is nil outside a gate window, so ordinary
# test scopes (e.g. a straggler run) collect nothing.
$gate_sops = nil

# Push one executed-SOP entry onto the open gate window (no-op outside one).
# String keys + scalar values only, so the buffer embeds .inspect-safe in the
# Base64 conductor payload. Never raises — collection must not break the run.
def gate_sop(sop, cmd, ok, duration_ms = nil)
  return unless $gate_sops

  entry = { "sop" => sop.to_s, "cmd" => cmd.to_s, "result" => ok ? "pass" : "fail" }
  entry["duration_ms"] = duration_ms.to_i if duration_ms
  $gate_sops << entry
rescue StandardError
  nil
end

# Open (or re-enter — GateRun.open! reuses the in-flight attempt) the release's
# gate attempt and start collecting SOPs. Best-effort + dry-run-suppressed.
def record_gate_open(release_slug, key, actor: nil)
  $gate_sops = []
  actor_ruby = actor.to_s.empty? ? "nil" : actor.to_s.inspect
  conductor(
    "run = GateRun.open!(subject_type: 'release', subject_slug: #{release_slug.inspect}, " \
    "key: #{key.inspect}, actor: #{actor_ruby}, source: 'conductor'); " \
    "puts({ gate: run.key, attempt: run.attempt }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ gate #{key} not opened — board write failed (#{e.message}); deploy continues")
end

# Close the gate attempt with its verdict + the collected SOPs, and stop
# collecting. Best-effort + dry-run-suppressed: callers in a SystemExit rescue
# MUST still re-raise after this — the close never masks an abort.
def record_gate_close(release_slug, key, success, metadata: {})
  sops = $gate_sops || []
  $gate_sops = nil
  # bin/release runs Rails-FREE, so no ActiveSupport .presence here — normalize
  # the metadata by hand (a non-Hash or nil becomes {}).
  meta = metadata.is_a?(Hash) ? metadata : {}
  conductor(
    "run = GateRun.close!(subject_type: 'release', subject_slug: #{release_slug.inspect}, " \
    "key: #{key.inspect}, success: #{success ? 'true' : 'false'}, sops: #{sops.inspect}, " \
    "source: 'conductor', metadata: #{meta.inspect}); " \
    "puts({ gate: run.key, attempt: run.attempt, success: run.success }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ gate #{key} not closed — board write failed (#{e.message}); deploy continues")
end

def record_release_event(release_slug, step_name, status, attrs = {})
  attrs = attrs.dup
  attrs[:source] ||= "conductor"
  attrs[:idempotency_key] ||= [
    release_slug, step_name, status, attrs[:repo], attrs[:app], attrs[:sha], attrs[:url]
  ].compact.join(":")

  payload = attrs.map { |key, value| "#{key}: #{value.inspect}" }.join(", ")
  conductor(
    "r = Release.find_by!(slug: #{release_slug.inspect}); " \
    "Release::Conductor.record_event!(release: r, step: #{step_name.inspect}, status: #{status.inspect}, #{payload}); " \
    "puts({ release_event: #{step_name.inspect}, status: #{status.inspect} }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ release event #{step_name}:#{status} not recorded (#{e.message}); deploy continues")
end

# --- deploy-side usage capture (best-effort) --------------------------------
# The conductor flips task stages on PROD via `heroku run`, where there is NO
# local transcript — so we capture the per-transition usage delta HERE (locally,
# in the release conductor's own session) and thread model/tokens/cost into the
# conductor snippet, which sets Current.task_event_* before the flip so the
# resulting TaskEvent carries usage. Mirrors bin/task's autofill: diff the
# session's cumulative totals against the baseline seeded at the matching
# `bin/task intent`, then advance the baseline. Resolves the same baseline dir as
# bin/task (honors TASK_USAGE_DIR; else <projects>/.agents/task-usage).
def release_usage_dir
  pinned = ENV["TASK_USAGE_DIR"].to_s.strip
  # Same live-store fallback bin/task carries, so it takes the same fail-closed
  # sandbox guard (lib/task_usage_sandbox.rb): under TASK_USAGE_SANDBOX an
  # unpinned run aborts rather than writing the operator's real cost store. The raw
  # fallback is the guard's ARGUMENT, not a local handed to it afterwards — see
  # bin/task#usage_dir and test/lib/state_store_containment_test.rb.
  TaskUsageSandbox.enforce!(
    pinned.empty? ? File.join(projects_root, ".agents", "task-usage") : pinned,
    store: "task-usage"
  )
end

# The captured per-transition usage for one task slug, or {} when there's no
# session / transcript / delta. String keys + scalar values, so it's safe inside
# the Ruby-literal conductor snippet (Base64-encoded by conductor_payload).
def capture_move_usage(slug)
  session, provider = conductor_session_identity
  return {} if session.to_s.empty?

  capture = TaskUsageBaseline.new(session: session, provider: provider, dir: release_usage_dir).capture_delta(slug)
  return {} unless capture

  usage = {}
  usage["model"] = capture.model if capture.model
  if capture.usage?
    usage["tokens_in"]  = capture.tokens_in
    usage["tokens_out"] = capture.tokens_out
    usage["cost"]       = format("%.4f", capture.cost) if capture.cost
  end
  usage
rescue StandardError
  {}
end

# The { slug => usage } map for a set of slugs (slugs with no capturable usage
# are dropped, keeping the snippet small). A no-op in --dry-run: capture_delta
# ADVANCES the baseline, and a dry-run must mutate nothing.
def move_usage_map(slugs)
  return {} if DRY

  Array(slugs).each_with_object({}) do |slug, map|
    usage = capture_move_usage(slug)
    map[slug] = usage unless usage.empty?
  end
end

# Thin wrappers over the pure, unit-tested Release::Cli parsers — they consume
# from this process's ARGV so the subcommands read the same way as before.
def opt_values(flag) = Release::Cli.opt_values(ARGV, flag)
def opt_value(flag)  = Release::Cli.opt_value(ARGV, flag)

def confirm(prompt)
  return true if ASSUME_YES || DRY

  # A non-interactive shell (no TTY) has no human to answer the prompt. The old
  # code read `$stdin.gets` → nil (EOF) → "" casecmp "y" → FALSE, so callers that
  # `return unless confirm(...)` (prepare) SILENTLY no-op'd — "looked like it ran
  # but nothing deployed", the SOP's flagged "dangerous one". Fail LOUDLY instead:
  # abort with the --yes escape hatch so a hands-off run must OPT IN to skipping
  # the gate rather than silently skipping the ACTION. This makes prepare's confirm
  # path consistent with ship/archive (which already `abort! unless confirm`).
  # --yes/--dry-run returned above, so they never reach here — the bypass is intact.
  abort!("non-interactive shell — pass --yes to run this non-interactively") unless $stdin.tty?

  $stdout.print("#{prompt} [y/N] ")
  answer = $stdin.gets
  # EOF (Ctrl-D) on an otherwise-interactive stdin: still no answer — abort, never
  # fold it into a false that a caller mistakes for a deliberate "no".
  abort!("EOF on stdin — pass --yes to run this non-interactively") if answer.nil?
  answer.strip.casecmp("y").zero?
end

# Poll <url>/up until it returns 200 (the dyno booted) or the attempts run out,
# sleeping `delay`s between tries. Returns true on a 200, false on timeout. This
# closes the /up-smoke race in `prepare`: `bin/qa-server deploy` returns once the
# push is accepted, but a slow dyno may still be booting, so the release would
# record QA + assemble against an app that isn't serving yet.
#
# An empty url (an app with no QA review url) returns true — there's nothing to
# smoke. A dry-run prints the plan and returns true (executes nothing).
def wait_for_boot(url, attempts: 30, delay: 5)
  return true if url.to_s.empty?
  if DRY
    step("wait for boot: poll #{url}/up until 200 (≤ #{attempts}×#{delay}s)")
    return true
  end

  step("wait for boot: #{url}/up (≤ #{attempts}×#{delay}s)")
  attempts.times do |i|
    code, = sh("/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "#{url}/up", capture: true)
    if code.to_s.strip == "200"
      say("  /up → 200 (booted after #{i + 1} poll#{i.zero? ? '' : 's'})")
      return true
    end
    break if i == attempts - 1

    sleep(delay)
  end
  say("  ⚠ /up never returned 200 after #{attempts} polls — dyno may still be booting")
  false
end

# --- post-deploy command hook ----------------------------------------------
# Run each release member's declared `devops.post_deploy_cmd` via `heroku run` on
# the just-deployed app — the QA heroku app on `prepare` (target: :qa), the
# production app on `ship` (target: :prod). The {task, app, cmd} plan + the
# QA-vs-prod target resolution are the unit-tested Release::PostDeploy.plan; this
# CLI owns only the `heroku run` I/O, the abort-on-failure, and the checks_run
# record. Commands are expected IDEMPOTENT, so a re-run after a failure just
# re-runs them (partial-deploy semantics: the release stays recoverable).
#
# Aborts the WHOLE pipeline on the first non-zero exit (so a bad backfill stops
# the release instead of shipping past it). A declared command with no resolvable
# target app (e.g. a gem, or an app missing from qa_environments.yml) is a hard
# abort — a declared command must never silently no-op. --dry-run PRINTS the
# command + target app and executes nothing.
def run_post_deploy(repos, target:)
  plan = Release::PostDeploy.plan(repos, qa_environments: QA_ENVIRONMENTS, target: target)
  return if plan.empty?

  phase  = target == :qa ? "QA" : "prod"
  subcmd = target == :qa ? "prepare" : "ship"
  say("")
  step("post-deploy hooks (#{phase}): #{plan.size} command(s)")
  plan.each do |entry|
    task = entry["task"]
    app  = entry["app"]
    cmd  = entry["cmd"]
    # Unroutable declared command (a gem, or an app missing from qa_environments)
    # is a HARD abort, never a silent no-op. Intentionally BEFORE the DRY gate: a
    # dry-run must surface this misconfig (it would block the real run) rather than
    # preview past it.
    abort!("task #{task} (#{entry['repo']}) declares a post_deploy_cmd but has no #{phase} app in " \
           "config/qa_environments.yml — register one or clear devops.post_deploy_cmd") if app.empty?

    # One canonical argv drives BOTH the preview and the real run, so --dry-run
    # prints exactly what executes. `--exit-code` makes `heroku run` passthrough the
    # REMOTE command's exit status — without it heroku returns 0 the instant the
    # dyno LAUNCHES (regardless of the command), so abort-on-failure never fires.
    # `--` stops heroku flag parsing so a task-declared cmd can't be reparsed as
    # `heroku run` flags; Shellwords.split keeps quoted/spaced args intact.
    heroku_argv = ["heroku", "run", "-a", app, "--no-tty", "--exit-code", "--", *Shellwords.split(cmd)]
    printed = heroku_argv.join(" ")

    if DRY
      say("  [dry-run] post-deploy #{task}: #{printed}")
      next
    end

    step("post-deploy #{task}: #{printed}")
    post_deploy_scope = target == :qa ? "qa_post_deploy" : "prod_post_deploy"
    out, ok = run_test_scope(post_deploy_scope, *heroku_argv, capture: true, repo: app, label: "#{task}: #{cmd}")
    print(out)
    record_post_deploy_check(task: task, app: app, cmd: cmd, ok: ok)
    # In ship, add successful runs to the partial-ship "what's live" trail.
    @ship_live << "post-deploy `#{cmd}` on #{app} (#{task})" if ok && defined?(@ship_live) && @ship_live
    abort!("post-deploy command failed for #{task} on #{app}: `#{cmd}` — fix it, then re-run " \
           "`bin/release #{subcmd}` (the command is idempotent; a re-run resumes)") unless ok
  end
end

# Stamp the [post-deploy] outcome on the member task's checks_run via the board
# conductor (read-merge-write, idempotent — see Release::Conductor). A board WRITE,
# so it routes through `conductor` (suppressed under --dry-run; run_post_deploy
# never reaches here in dry-run, but the gate keeps it safe).
def record_post_deploy_check(task:, app:, cmd:, ok:)
  conductor(
    "c = Release::Conductor.record_post_deploy_check(" \
    "task_slug: #{task.inspect}, app: #{app.inspect}, cmd: #{cmd.inspect}, ok: #{ok.inspect}); " \
    "puts({ task: #{task.inspect}, checks: c.size }.to_json)"
  )
end

# --- gem publishing (producer-first) ---------------------------------------
# Build + push one gem, then tag its repo. Each failure aborts loudly with the
# fix, never swallowed — a half-published release is worse than a stopped one.
def publish_gem(repo, version)
  path = repo_path(repo)
  abort!("gem repo not found at #{path} — clone it as a sibling at the projects root") unless DRY || Dir.exist?(path)

  meta    = RELEASE_REPOS.dig("gems", repo) || {}
  gemspec = meta["gemspec"].to_s.empty? ? "#{repo}.gemspec" : meta["gemspec"]
  artifact = File.join(Dir.tmpdir, "release-#{repo}-#{version}.gem")

  # 1. Gate on the gem's own release-check (--build = syntax + unit + build) when
  #    it ships one, so a red gem never gets pushed.
  if (rc = meta["release_check"]) && (DRY || File.exist?(File.join(path, rc)))
    step("gem check: #{repo} #{rc} --build")
    _, ok = run_test_scope("gem_release_check", rc, "--build", chdir: path, repo: repo, label: "#{rc} --build")
    abort!("#{repo} release-check failed — fix before publishing (nothing pushed)") unless ok || DRY
  end

  # 2. Build the push artifact at a known path.
  step("gem build: #{repo} #{gemspec} → #{artifact}")
  _, built = sh("gem", "build", gemspec, "--output", artifact, chdir: path)
  abort!("gem build failed for #{repo} #{version} — aborting before push") unless built || DRY

  # 3. Push to RubyGems.
  step("gem push: #{artifact}")
  _, pushed = sh("gem", "push", artifact)
  abort!("gem push failed for #{repo} #{version} — already published? bump #{meta['version_file']} (its PR owns the version) or check `gem signin`. Nothing downstream deployed.") unless pushed || DRY

  # 4. Tag the gem repo so the published version is reproducible from git.
  tag = "v#{version}"
  step("git tag #{tag} in #{repo}")
  sh("git", "-C", path, "tag", "-a", tag, "-m", "Release #{repo} #{tag}")
  _, tagged = sh("git", "-C", path, "push", "origin", tag, capture: true)
  say("  (tag #{tag} push #{tagged ? 'ok' : 'skipped/failed — push it manually if needed'})") unless DRY
end

# --- init ------------------------------------------------------------------
# One-time, idempotent: create the persistent `release` branch from origin/main
# in every gem + app repo that doesn't already have one. Re-runnable — a repo
# that already has origin/release is skipped.
def init
  say("Init persistent `release` branches#{DRY ? ' — DRY RUN' : ''}")
  release_repo_slugs.each do |repo|
    path = repo_path(repo)
    unless DRY || Dir.exist?(path)
      say("  - #{repo}: SKIP (not checked out at #{path})")
      next
    end

    sh("git", "-C", path, "fetch", "origin", "--quiet")

    # Existence is a read — check it for real outside dry-run; in dry-run we
    # always PREVIEW the push so the plan is visible.
    unless DRY
      _, exists = sh("git", "-C", path, "rev-parse", "--verify", "--quiet", "origin/release", capture: true)
      if exists
        say("  - #{repo}: origin/release already exists — skip")
        next
      end
    end

    step("push release branch in #{repo}: origin/main → origin/release")
    _, pushed = sh("git", "-C", path, "push", "origin", "origin/main:refs/heads/release")
    say("  - #{repo}: created origin/release from origin/main") if pushed || DRY
  end
  say("")
  say("✓ Persistent `release` branches ready#{DRY ? ' (DRY RUN — nothing executed)' : ''}.")
end

# --- merge -----------------------------------------------------------------
# The SWEEP primitive, accepted-ladder edition. Review already merged each feat PR
# into `accepted` (merged:"accepted"), so this no longer merges per-task feat PRs:
# it PROMOTES all of `accepted` onto the persistent `release` branch via ONE batch
# PR per repo (promote_accepted_to_release!) and records the NAMED slugs' membership
# in ONE `heroku run` (membership + merged:"release"; stages don't move — the
# `reviewed`→`assembled` flip is prepare's QA-green step, and an `assembled`
# straggler keeps its stage). A named task with no code on `accepted` (merged:"")
# ABORTS (review must land it first); a task already `merged: release/main` skips
# the promote (crash recovery) but still records.
#
# BATCHED + crash-safe: the resolve is ONE read and the record is ONE write (single
# dyno spin-up). The promote is git-FIRST and fail-closed (a conflict/missing
# checkout aborts before anything is recorded); it's idempotent — accepted level
# with release → skip the PR, and a gh-merge failure falls back to pr_merged? (an
# interrupted prior run merged it), so the half-state self-heals rather than wedging.

# The one-shot read snippet that resolves EVERY merge slug's PR + `merged`
# git-location AND runs the review-gate screen in a SINGLE conductor call (one
# heroku-run spin-up for the whole batch). Pure string builder (slugs are
# alnum/hyphen, safe under .inspect — same as the existing single-slug
# `slug.inspect` literals; `override` is a bare bool literal). The screen is a
# PURE read (Release::Conductor.screen_merge writes nothing), so it's safe inside
# this read-only resolve and previews under --dry-run. Emits ONE JSON line:
#   { "tasks": [ { slug, pr_url, repo, stage, merged } | { slug, missing: true } ],
#     "screen": { rows:[…], blocked:[…], overridden:[…], missing:[…], proceed: } }
def batch_resolve_ruby(slugs, override: false)
  "slugs = #{slugs.inspect}; " \
  "rows = slugs.map { |s| t = Task.find_by(slug: s); " \
  "t ? { slug: t.slug, pr_url: t.devops_url('pr').to_s, repo: t.release_repo.to_s, stage: t.stage, merged: t.merged.to_s } " \
  ": { slug: s, missing: true } }; " \
  "screen = Release::Conductor.screen_merge(slugs, override: #{override ? 'true' : 'false'}); " \
  "puts({ tasks: rows, screen: screen }.to_json)"
end

# The one-shot write snippet that sweeps EVERY slug in a SINGLE `heroku run` — N
# membership writes on one dyno, instead of a cold `heroku run` per PR. sweep! is
# idempotent/crash-safe (see Release::Conductor: an already-`merged` member is
# untouched, never regressed), so a re-run is safe. `override` threads the
# audited review-gate bypass through to sweep! — harmless for already-sweepable
# members (records no skip); an unreviewed member is flipped to `reviewed` with
# the `review_bypassed` audit event stamped on that transition. No usage map:
# the sweep writes NO stage transition (the reviewed→assembled flip — and its
# usage capture — happens at prepare's QA-green step).
# Emits ONE JSON line: { "swept": [...], "slug": <last release>, "state" }.
def batch_sweep_ruby(slugs, override: false)
  "slugs = #{slugs.inspect}; " \
  "results = slugs.map { |s| r = Release::Conductor.sweep!(Task.find_by!(slug: s), override: #{override ? 'true' : 'false'}); " \
  "{ task: s, release: r.slug, state: r.state } }; " \
  "last = results.last; " \
  "puts({ swept: results, slug: (last && last[:release]), state: (last && last[:state]) }.to_json)"
end

# Is this PR already merged on GitHub? The gh-side crash-recovery read: when a
# prior run merged the PR but died before the record write (so `merged` is still
# nil), the next run's `gh pr merge` fails — this read distinguishes "already
# merged, carry on" from a genuine merge failure. Read-only; goes straight to
# Open3 (runs even in --dry-run).
def pr_merged?(pr_url)
  out, status = Open3.capture2e("gh", "pr", "view", pr_url, "--json", "state", "-q", ".state")
  status.success? && out.strip == "MERGED"
end

# Review-gate guard for the sweep (`bin/release merge` + `prepare`). The
# DECISION (which slugs are blocked vs overridden) is
# Release::Conductor.screen_merge's — this only renders it: it ABORTS the whole
# run when any requested task isn't sweepable (`reviewed`, or an `assembled`
# straggler) and no --override was given, naming exactly which task is in which
# stage and how to override; or prints a loud OVERRIDE banner for the bypassed
# tasks (whose skip sweep! records on the audit spine). A `nil`/empty screen
# (e.g. a stub-less dry preview) is a no-op. Both lists carry the offending
# task's actual stage, pulled from screen rows, so the operator sees "task X is
# in stage Y" without re-reading the board.
def enforce_review_gate!(screen)
  rows  = Array(screen["rows"])
  stage = ->(slug) { (rows.find { |r| r["slug"] == slug } || {})["stage"] || "unknown" }

  blocked = Array(screen["blocked"])
  if blocked.any?
    named = blocked.map { |slug| "#{slug} (#{stage.call(slug)})" }.join(", ")
    abort!("review gate: #{named} #{blocked.size == 1 ? 'is' : 'are'} not sweepable (`reviewed`/`assembled`) — " \
           "get the PR(s) through review first, or pass --override to sweep anyway " \
           "(the skip is recorded as a `review_bypassed` audit event).")
  end

  overridden = Array(screen["overridden"])
  return if overridden.empty?

  named = overridden.map { |slug| "#{slug} (#{stage.call(slug)})" }.join(", ")
  say("  ⚠ OVERRIDE: sweeping #{named} past the review gate — recording a `review_bypassed` audit event per task.")
end

# The merged-stamp value review writes when a feat PR lands on `accepted` — the
# git-location "code is on accepted" ticket the sweep promotes. Same string as the
# branch name, kept as its own const so the merged-state compare reads as intent.
ACCEPTED_MERGED = "accepted"

# Promote each repo's `accepted` branch onto its `release` branch — the accepted-
# ladder's SECOND rung (it replaces the sweep's N per-feat-PR merges). Review already
# merged each feat PR into `accepted` and stamped merged:"accepted"; this lands ALL
# of that accumulated work onto `release` via ONE batch PR PER REPO (a single-repo
# release is exactly one PR, not N per task). Git-side + fail-closed PER repo:
#   * `git -C <path> fetch`, then ahead = rev-list origin/release..origin/accepted.
#   * ahead == 0 (accepted level with release — nothing new, or a prior run already
#     promoted): SKIP the PR. The caller STILL records membership + deploys — the
#     reviewed members must ride THIS RC even when the code already landed.
#   * ahead > 0: reuse an OPEN accepted→release PR or open one (`--base release
#     --head accepted`), `gh pr merge` it. A gh-merge failure falls back to
#     pr_merged? (an interrupted prior run merged it, its record write died) →
#     treat as promoted; otherwise ABORT (fail-closed — nothing recorded, members
#     stay `reviewed` for a clean re-run). A missing local checkout ABORTS too
#     (never record members whose code was not promoted).
# A DRY run PREVIEWS the one-batch-PR-per-repo plan without any git/gh call (so the
# preview is hermetic and prints exactly ONE promote line per repo). `label` names
# the RC in the PR title when known (the --slug option; nil → a generic title).
def promote_accepted_to_release!(repos, label: nil)
  Array(repos).map(&:to_s).reject(&:empty?).uniq.each do |repo|
    if DRY
      step("promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH} in #{repo}: open/reuse ONE " \
           "`gh pr create --base #{RELEASE_BRANCH} --head #{ACCEPTED_BRANCH}` batch PR and merge it")
      next
    end

    path = repo_path(repo)
    abort!("app repo not found at #{path} — clone it as a sibling to promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH} " \
           "(nothing recorded; members stay `reviewed`)") unless Dir.exist?(path)

    sh("git", "-C", path, "fetch", "origin", RELEASE_BRANCH, ACCEPTED_BRANCH, "--quiet", capture: true)
    ahead_out, ahead_ok = sh("git", "-C", path, "rev-list", "--count",
                             "origin/#{RELEASE_BRANCH}..origin/#{ACCEPTED_BRANCH}", capture: true)
    abort!("could not compare origin/#{RELEASE_BRANCH}..origin/#{ACCEPTED_BRANCH} in #{repo} " \
           "(`git rev-list` failed) — fetch, then re-run `bin/release prepare`.") unless ahead_ok
    ahead = ahead_out.strip.to_i
    if ahead.zero?
      step("#{repo}: `#{ACCEPTED_BRANCH}` is level with `#{RELEASE_BRANCH}` — nothing to promote " \
           "(skip the batch PR; membership still records)")
      next
    end

    pr_url = accepted_release_pr_url(repo, label: label)
    step("gh pr merge #{pr_url} --merge — promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH} in #{repo} " \
         "(#{ahead} commit#{ahead == 1 ? '' : 's'})")
    _, ok = sh("gh", "pr", "merge", pr_url, "--merge", capture: false)
    if !ok && pr_merged?(pr_url)
      say("  ↷ #{pr_url} already merged (interrupted prior run) — continuing to the record step")
      ok = true
    end
    abort!("gh pr merge failed for the #{ACCEPTED_BRANCH}→#{RELEASE_BRANCH} batch PR in #{repo} (#{pr_url}) — " \
           "resolve it on GitHub (conflicts/checks), then re-run `bin/release prepare`.") unless ok
  end
end

# Find the OPEN accepted→release batch PR for a repo, or open one — idempotent
# across interrupted runs (reuse, never a duplicate). Scoped to the repo via
# `--repo owner/name` so it needs no chdir; aborts fail-closed if the PR can't be
# opened. (Live gh — only reached in a non-DRY promote.)
def accepted_release_pr_url(repo, label: nil)
  nwo = repo_name_with_owner(repo)
  repo_args = nwo.empty? ? [] : ["--repo", nwo]

  existing, ok = sh("gh", "pr", "list", *repo_args, "--base", RELEASE_BRANCH, "--head", ACCEPTED_BRANCH,
                    "--state", "open", "--json", "url", "-q", ".[0].url", capture: true)
  return existing.strip if ok && !existing.strip.empty?

  title = label.to_s.empty? ? "Promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH}" \
                            : "Promote #{ACCEPTED_BRANCH} → #{RELEASE_BRANCH} (#{label})"
  body = "Batch promotion of the accepted-ladder: lands every reviewed change already merged onto " \
         "`#{ACCEPTED_BRANCH}` onto `#{RELEASE_BRANCH}` for QA. Opened by `bin/release prepare`."
  out, created = sh("gh", "pr", "create", *repo_args, "--base", RELEASE_BRANCH, "--head", ACCEPTED_BRANCH,
                    "--title", title, "--body", body, capture: true)
  abort!("could not open the #{ACCEPTED_BRANCH}→#{RELEASE_BRANCH} batch PR in #{repo} (`gh pr create` failed) — " \
         "open it by hand (`gh pr create --base #{RELEASE_BRANCH} --head #{ACCEPTED_BRANCH}`), then re-run.") unless created
  out.strip
end

def merge
  # `--override` is the audited review-gate escape hatch — consume it BEFORE
  # positional_slugs reads the rest (take_flag deletes it from ARGV so it's never
  # mistaken for a slug).
  override = Release::Cli.take_flag(ARGV, "--override")
  slugs = Release::Cli.positional_slugs(ARGV)
  abort!("usage: bin/release merge <task-slug> [<task-slug> ...] [--override]") if slugs.empty?

  say("Sweep #{slugs.join(', ')} onto `#{RELEASE_BRANCH}`#{PROD ? ' (PROD board)' : ' (local)'}#{override ? ' (OVERRIDE)' : ''}#{DRY ? ' — DRY RUN' : ''}")

  # 1. Resolve ALL the tasks' PRs + `merged` git-location AND run the review-gate
  #    screen in ONE read (one heroku-run spin-up for the whole batch; a read —
  #    runs even in dry-run).
  step("record (read-only): resolve #{slugs.size} task PR(s)")
  resolved = conductor(batch_resolve_ruby(slugs, override: override), read_only: true)
  infos = resolved["tasks"] || []

  missing = infos.select { |i| i["missing"] }.map { |i| i["slug"] }
  abort!("task(s) not found on the board: #{missing.join(', ')}") if missing.any?
  infos.each do |i|
    at = i["merged"].to_s.empty? ? "" : " · merged: #{i['merged']}"
    say("  task #{i['slug']} (#{i['stage']}#{at}) · #{i['repo']} · #{i['pr_url']}")
  end

  # 1b. REVIEW-GATE GUARD (the decision lives in Release::Conductor.screen_merge;
  #     this only prints + aborts). Runs BEFORE the accepted→release promote: an
  #     unsweepable task ABORTS the whole run unless --override is given. With --override,
  #     the offending tasks proceed but the skip is recorded as a
  #     `review_bypassed` audit event when sweep! flips them to `reviewed`.
  enforce_review_gate!(resolved["screen"] || {})

  # 2. The SWEEP PLAN (pure: Release::SweepPlan): partition the named tasks into the
  #    members to RECORD (code on accepted/release/main) and HELD anomalies (a task
  #    with no merged stamp — review never landed its feat PR on `accepted`). For
  #    this EXPLICIT command a held task is a HARD abort: the operator named it and
  #    there is no code on `accepted` to promote — silently dropping it would lie.
  plan = Release::SweepPlan.compute(infos)
  if plan["held"].any?
    abort!("task(s) have no code on `#{ACCEPTED_BRANCH}` (merged:\"\") — review must land the feat PR on " \
           "`#{ACCEPTED_BRANCH}` first: #{plan['held'].join(', ')}")
  end
  plan["record"].reject { |row| row["merged"] == ACCEPTED_MERGED }.each do |row|
    step("skip promote for #{row['slug']} — already merged: #{row['merged']} (crash recovery); membership still records")
  end

  # 3. PROMOTE accepted → release (the accepted-ladder's SECOND rung). SEMANTIC
  #    NARROWING (accepted-ladder): `merge <slug>` no longer merges the named task's
  #    ONE feat PR — review already merged it into `accepted`. It now promotes ALL of
  #    `accepted` onto `release` via ONE batch PR per repo and records the NAMED
  #    slugs' membership. So it lands EVERY reviewed change on `accepted`, not just
  #    the named one — use it to force a specific reviewed task onto the RC ahead of
  #    the sweep. Idempotent + fail-closed (accepted level with release → skip the
  #    PR, still record). Git-FIRST (the irreversible step), then the record write.
  promote_repos = infos.select { |i| i["merged"].to_s == ACCEPTED_MERGED }
                       .map { |i| i["repo"].to_s }.reject(&:empty?).uniq
  promote_accepted_to_release!(promote_repos) if promote_repos.any?

  # 4. BATCHED record: ALL named members in ONE `heroku run` (single dyno spin-up,
  #    N membership writes; conductor suppresses the write under --dry-run). Stages
  #    don't move here — prepare's QA-green flips `reviewed` members to `assembled`;
  #    a swept straggler is already there.
  swept = plan["sweep"]
  if swept.any?
    step("record: Release::Conductor.sweep! ×#{swept.size} in ONE run (#{swept.join(', ')})")
    @merge_result = conductor(batch_sweep_ruby(swept, override: override))
  end

  result = @merge_result || {}
  say("")
  say("✓ Swept #{swept.join(', ')} onto `#{RELEASE_BRANCH}`#{DRY ? ' (DRY RUN — nothing executed)' : ''} — stages don't move: `reviewed` members flip `assembled` at QA-green (assembled stragglers keep their stage).")
  say("  release #{result['slug']} (#{result['state']}) — `bin/release prepare` deploys QA and flips members `assembled` on green.") unless DRY || result.empty?
end

# --- prepare (Steffon's self-healing qa-deploy) ------------------------------

# The one-shot DETECTION read: every `reviewed` task + any `assembled` straggler
# off the current RC — each with its PR url, repo, and `merged` git-location —
# plus the review-gate screen over exactly those slugs and the current release.
# `only_slugs` (from --task) narrows the sweep to the named tasks. A PURE read
# (sweep_candidates + screen_merge write nothing), so it previews under
# --dry-run. Emits ONE JSON line:
#   { "tasks": [{slug, stage, merged, pr_url, repo}], "release": {slug,state}|null,
#     "screen": { rows:[…], blocked:[…], … } }
def sweep_detect_ruby(only_slugs)
  only = only_slugs.empty? ? "nil" : only_slugs.inspect
  "only = #{only}; " \
  "c = Release::Conductor.sweep_candidates; " \
  "tasks = c['reviewed'] + c['stragglers']; " \
  "tasks = tasks.select { |t| only.include?(t.slug) } if only; " \
  "rows = tasks.map { |t| { slug: t.slug, stage: t.stage, merged: t.merged.to_s, " \
  "pr_url: t.devops_url('pr').to_s, repo: t.release_repo.to_s } }; " \
  "screen = Release::Conductor.screen_merge(rows.map { |x| x[:slug] }); " \
  "r = Release.current; " \
  "puts({ tasks: rows, release: (r ? { slug: r.slug, state: r.state } : nil), screen: screen }.to_json)"
end

# The one-shot SWEEP write for prepare: open the candidate if none is active
# (honoring an explicit --slug), sweep! every landed slug (membership +
# merged:"release"; stages don't move), validate the members, and return the
# per-repo deploy plan — ONE `heroku run` for the whole batch. TRANSACTIONAL: a
# validate_members! raise rolls the whole sweep back; the gh merges already
# landed, but the next run self-heals (the gh-merge failure falls back to
# pr_merged?). Emits ONE JSON line: { slug, state, swept, repos }.
def batch_sweep_with_plan_ruby(slugs, release_slug = nil)
  open_ruby = release_slug ? "Release.open!(slug: #{release_slug.inspect}) if Release.current.nil?; " : ""
  "result = Release.transaction { #{open_ruby}" \
  "slugs = #{slugs.inspect}; " \
  "slugs.each { |s| Release::Conductor.sweep!(Task.find_by!(slug: s)) }; " \
  "r = Release.current_or_open!; " \
  "Release::Conductor.validate_members!(r); " \
  "{ slug: r.slug, state: r.state, swept: slugs, repos: Release::Conductor.repo_plan(r) } }; " \
  "puts(result.to_json)"
end

# The pre-QA gate command an app registers in config/release_repos.yml
# (`qa_test_cmd`) — the tier prepare owns (Release::STEP_TEST_TIERS["prepare"]):
# satellites register their integration subset; the HUB registers its FULL
# suite (the G3 batch certification that lets ship's test_gate self-gate an
# unchanged SHA). "" = not registered → the repo self-gates (its suite runs at
# ship's test_cmd / its own deploy) and the gate skips it.
def qa_gate_cmd(repo) = app_meta_for(repo)["qa_test_cmd"].to_s

# Parse a registry test command (`test_cmd` / `qa_test_cmd`) into the argv `sh`
# execs — Shellwords, not String#split, so quoted/spaced args survive as single
# elements (same policy as the heroku-run payload seam above). Identical to a
# plain split for the flag-style commands the registry carries today, so the
# switch is behavior-preserving. A malformed value (unbalanced quote) aborts
# NAMING the string instead of executing a garbled command.
def test_cmd_argv(cmd)
  Shellwords.split(cmd)
rescue ArgumentError => e
  abort!("unparseable test command #{cmd.inspect} (#{e.message}) — fix it in config/release_repos.yml")
end

# --- primary-checkout lock ---------------------------------------------------
# Serializes what STILL flips the primary's HEAD. As of 2026-07-12 that is ONE
# caller: the artifact-commit dance (commit_artifact_to_release), which checks out
# `release` to commit a generated doc and returns to `main`.
#
# The gate suites moved to the gate workspace, and the SHIP moved to its own
# workspace + ref pushes (push_frozen_main / repin_consumers / deploy_app) — so
# neither takes this lock any more, and neither can be blocked by it. The one
# remaining ship-side read of a primary is the GEM artifact build
# (checkout_detached), which is guarded by the ship preflight instead.
#
# ROOT CAUSE it guards against (rel-20260708-496cd8): the pre-QA gate ran its
# full suite in the primary hub checkout on `release` (~6-min critical section)
# while a concurrent `bin/release archive`/`retro` artifact dance flipped that
# same checkout main↔release five times — the suite's lazily-loaded routes/views
# then resolved against PRE-merge code → 7 false failures → a false-negative G3.
#
# flock, not a mkdir lock: the OS releases it when the holder dies, so a killed
# holder can never wedge the next conductor run. Per-repo (keyed by repo name) so
# a hub run never blocks a satellite's artifact commit.
#
# The lock dir is FIXED at <projects_root>/.agents/locks (the dir that already
# anchors cross-checkout state like the worktree registry) — NOT Dir.tmpdir:
# two conductors launched with different TMPDIR values must still contend on
# the SAME file. MCR_PRIMARY_LOCK_DIR overrides it; every test that exercises
# this lock MUST point it at a per-test tmpdir — the real dir belongs to the
# live conductor, and a test flocking it while a G3 gate (which holds it for
# its whole suite run) executes that test would deadlock the gate against
# itself.
# The lock dir RESOLVED — pure: no guard, no IO. Split out from the seam below so a
# test can assert the DEFAULT shape (<projects>/.agents/locks) without asking the code
# to mkdir_p the operator's real store in order to prove where it is. It used to do
# exactly that: the two "defaults to" tests deleted MCR_PRIMARY_LOCK_DIR and called
# the seam, so every suite run created the live <projects>/.agents/locks.
def primary_checkout_lock_dir
  dir = ENV["MCR_PRIMARY_LOCK_DIR"].to_s
  dir.empty? ? File.join(projects_root, ".agents", "locks") : dir
end

# THE CHOKE POINT for the lock store — guard, then create. Committed to creating a
# file from here (both callers flock it with File::CREAT), so the guard comes BEFORE
# mkdir_p, the same seam bin/task's write_feature_marker guards at. Under
# TASK_USAGE_SANDBOX an unpinned MCR_PRIMARY_LOCK_DIR aborts instead of falling back
# onto the LIVE conductor's lock dir — a test that flocks the real file can deadlock a
# running G3 gate against itself (that gate holds the lock for its whole suite run).
# The comment above has always SAID every test must pin it; this makes the pin a
# guarantee rather than a request.
def guarded_lock_dir
  dir = TaskUsageSandbox.enforce!(primary_checkout_lock_dir, store: "agent-locks")
  FileUtils.mkdir_p(dir)
  dir
end

def primary_checkout_lock_path(repo)
  File.join(guarded_lock_dir, "mcr-primary-checkout-#{repo}.lock")
end

# --- the workspace locks (gate + ship) ---------------------------------------
# A workspace is PRIVATE to the conductor, not to a PROCESS: its path
# (<repo>/.worktrees/_gate, <repo>/.worktrees/_ship) and its DB
# (<repo>_gate_test, <repo>_ship_test) are FIXED. So while no agent session or
# hand-run command can touch it, ANOTHER `bin/release` can — and two concurrent
# conductors are a documented occurrence here (two QA-release sessions have
# raced). Unlocked, conductor B's `reset --hard` would move the tree and its
# `db:test:prepare` would PURGE the DB under conductor A's live, lazily-autoloading
# suite: the exact two root causes the gate workspace exists to close, relocated
# one directory over (plus the parallel-full-suite SIGSEGV class).
#
# So each workspace takes its OWN lock, PER ROLE (gate / ship) and per repo, held
# across pin → prepare → use. Per role because the DEPLOY must never queue behind a
# concurrent conductor's G3 suite — or worse, reset the tree under it.
#
# PRECISELY (the ship is not wholly free of the gate lock, and the claim should not
# be overstated — jasper, PR #517): the ship's own TEST GATE (test_gate) runs its
# suite in the GATE workspace under the GATE lock, so it CAN queue behind a
# concurrent conductor's G3 suite. That is correct and deliberate — it is the same
# suite on the same tree, and it is pre-authority, so a wait costs nothing
# irreversible. What must never queue is everything AFTER ship authority — the
# re-pin, the deploys — and none of it touches the gate lock.
#
# Deliberately NOT the primary-checkout lock: the primary must stay FREE (feature
# sessions use it, and monopolising it for the length of a suite was half of what
# made the old gate hostile). Never nested inside the primary lock, so the two
# can't deadlock.
#
# NOTE on MCR_PRIMARY_LOCK_DIR: despite its name it overrides the lock DIRECTORY,
# not the primary lock alone — every bin/release lock lives there, and the tests
# isolate ALL of them by pointing it at a tmpdir. Do not "fix" the naming by giving
# a lock its own dir: a split would silently un-isolate one of them.
def gate_workspace_lock_path(repo, role: "gate")
  File.join(guarded_lock_dir, "mcr-#{Release::GateWorkspace.role!(role)}-workspace-#{repo}.lock")
end

# Run the block holding `repo`'s WORKSPACE lock for `role`. Always waits: a queued
# run is correct (the other conductor is using the same tree), where proceeding
# concurrently is guaranteed corruption.
def with_gate_workspace(repo, role: "gate")
  File.open(gate_workspace_lock_path(repo, role: role), File::RDWR | File::CREAT, 0o644) do |f|
    unless f.flock(File::LOCK_EX | File::LOCK_NB)
      holder = role == "ship" ? "another bin/release is deploying from that checkout" \
                              : "another bin/release is running its gate suite"
      say("  waiting on the #{repo} #{role}-workspace lock (#{holder})…")
      f.flock(File::LOCK_EX)
    end
    yield
  end
end

# The SHIP workspace's lock — the deploy's own checkout. Same flock discipline,
# a DIFFERENT file from the gate's, so a prod deploy never queues behind (or races)
# a concurrent conductor's G3 gate suite.
def with_ship_workspace(repo, &block)
  with_gate_workspace(repo, role: "ship", &block)
end

# Run the block holding `repo`'s primary-checkout lock.
#   wait: true  — queue behind the current holder (flips are seconds; the one
#                 long holder is the gate suite, and callers that MUST proceed
#                 — the gate itself, ship's ff — are correct to wait).
#   wait: false — best-effort: return :busy WITHOUT yielding when another
#                 invocation holds the checkout (the artifact dance skips
#                 rather than stall an archive/retro behind a ~6-min suite).
def with_primary_checkout(repo, wait: true)
  File.open(primary_checkout_lock_path(repo), File::RDWR | File::CREAT, 0o644) do |f|
    unless f.flock(File::LOCK_EX | File::LOCK_NB)
      return :busy unless wait

      say("  waiting on the #{repo} primary-checkout lock (another bin/release invocation is flipping it)…")
      f.flock(File::LOCK_EX)
    end
    yield
  end
end

# --- gate suite ruby pin: run the gate suite under CI's ruby -----------------
# The gates spawn `bin/rails test`; that suite's deploy-tooling meta-tests spawn
# bin/release / bin/dor-check subprocesses (`#!/usr/bin/env ruby`) that resolve
# `ruby` off PATH. On this gate host PATH's ruby is brew's (the app ruby, by
# design), whose gem home DIVERGES from mise's → a `Gem::Platform::JAVA already
# initialized` collision at subprocess boot → FALSE gate failures (CI, on mise
# 3.3.11, is green). So we run every gate subprocess — the suite, plus the bundle
# check/install + suite-ruby probe below — with mise's ruby bin dir leading PATH
# (an env overlay via `env:`, NOT an argv wrap, so command stubs keying on argv[0]
# still match): mise's `env ruby` wins the shebang lookup for the command AND its
# children, so local == CI. Degrades to the shell ruby (empty overlay) + a loud
# note, ONCE, when the pinned ruby isn't installed. See Release::GateRuby.
#
# Memoized so the note prints once per run, not once per repo. The empty-Hash
# overlay ({}) is a valid memo — an mise-less host still short-circuits after one note.
def gate_ruby_bin_dir
  return @gate_ruby_bin_dir if defined?(@gate_ruby_bin_dir)

  @gate_ruby_bin_dir = Release::GateRuby.resolve_ruby_bin_dir
  if @gate_ruby_bin_dir
    say("  gate ruby: mise #{Release::GateRuby::RUBY_PIN} (#{@gate_ruby_bin_dir}) leads PATH — matches CI")
  else
    say("  ⚠ gate ruby: mise #{Release::GateRuby::RUBY_PIN} not installed (#{Release::GateRuby.install_dir}) — " \
        "the gate suite runs under the shell ruby (#{RbConfig.ruby}). On a host whose `ruby` isn't mise this can " \
        "diverge from CI (deploy-tooling meta-tests hit a brew/mise gem-home split). Install it: " \
        "mise install ruby@#{Release::GateRuby::RUBY_PIN}")
  end
  @gate_ruby_bin_dir
end

# The FULL gate overlay for a repo: the mise ruby pin + the agent-session scrub +
# the gate's private TEST_DATABASE_URL (Release::GateEnv). Every gate subprocess —
# the suite, its bundle check/install, the db:test:prepare, and every grandchild
# they spawn — runs under this, so `local == CI` on all three axes. Memoized per
# repo (the ruby note prints once per run, from gate_ruby_bin_dir).
def gate_env(repo, role: "gate")
  @gate_env ||= {}
  @gate_env[[repo, role]] ||= Release::GateEnv.env(
    ruby_bin_dir: gate_ruby_bin_dir.to_s,
    # nil for a SQLite app (rolio): its test DB is a file INSIDE the workspace,
    # already private — and handing it a postgres URL would be a live trap.
    test_database_url: gate_database_url(repo, role: role)
  )
end

# --- suite-toolchain guard: bundle check/install under the SUITE ruby --------
# The gate boots its suite via the repo's binstubs (`#!/usr/bin/env ruby`), so
# the ruby that matters is the one `ruby` resolves to FROM THE REPO DIR — on
# this machine mise's pinned 3.3.11 (mise shims are directory-sensitive). The
# conductor/operator shell's own `bundle` can resolve a DIFFERENT ruby (brew's
# ruby@3.3) with a DIVERGENT gem home, so a shell-side `bundle check` LIES
# about the suite's env. ROOT CAUSE (rel-20260708-32701b): PR #456's
# studio-engine 0.11→0.12 bump was "satisfied" in brew's gem home but missing
# from mise's (the one the suite boots) → Bundler::GemNotFound at suite boot →
# the gate aborted TWICE with eject/revert regression guidance for a pure env
# problem. So the check/install run through the repo's `bin/bundle` binstub —
# the SAME env-resolved ruby that boots the suite — and a still-broken bundle
# aborts NAMING the toolchain divergence (env diagnosis), never the eject path.

# The bundle ARGV that resolves ruby EXACTLY like the suite's own binstubs — so
# the check reads the SAME gem home the suite boots against, for EVERY
# qa-registered app, not only ones carrying a checked-in bin/bundle. Two forms:
#   * ["bin/bundle"]        — the repo's binstub (`#!/usr/bin/env ruby` → the
#     env-resolved ruby, i.e. mise's directory pin); every Rails app checkout
#     ships one.
#   * ["ruby", "-S", "bundle"] — the fallback when a registered repo has NO
#     bin/bundle binstub. Run with chdir: path, the bare `ruby` ALSO resolves
#     through the mise shim's directory pin, so `-S bundle` runs the bundler
#     that ruby's OWN gem home ships. This is the fix carl + shannon flagged on
#     PR #480: the old bare-`bundle` fallback did a shell PATH lookup that
#     re-picked the conductor's ruby — the exact brew-vs-mise divergence the
#     guard exists to close, so no-binstub apps had NO real same-ruby coverage.
def suite_bundle_argv(path)
  File.exist?(File.join(path, "bin", "bundle")) ? ["bin/bundle"] : ["ruby", "-S", "bundle"]
end

# The ruby the suite will boot with — probed under the SAME gate env overlay the
# suite runs through (mise's pinned 3.3.11 when available; see gate_env), so
# the diagnosis below names the ruby the suite ACTUALLY boots, not the conductor
# shell's. Degrades to "unknown" (never aborts) on a failed probe: this string
# only enriches the mismatch diagnosis below.
def suite_ruby(repo, path)
  out, ok = sh("ruby", "-e", "print RbConfig.ruby", chdir: path, capture: true, env: gate_env(repo))
  ok && !out.strip.empty? ? out.strip : "unknown (ruby probe failed)"
end

# Verify the GATE WORKSPACE's bundle under the suite ruby BEFORE burning a
# multi-minute suite run: check → self-heal with install → abort as ENV.
# Runs in the isolated gate workspace, INSIDE the gate-workspace lock (another
# bin/release CAN reach that tree — see with_gate_workspace),
# AFTER it is pinned at the SHA under test, so it reads the exact Gemfile.lock the
# suite will load.
def ensure_suite_bundle!(repo, path, role: "gate")
  # No Gemfile in the release tree → nothing bundler-managed to verify
  # (self-gating, like an app with no qa_test_cmd).
  return unless File.exist?(File.join(path, "Gemfile"))

  # Verify under the gate-ruby env pin so the bundle is checked against the SAME
  # ruby the suite now boots (mise's pin) — otherwise a brew-satisfied /
  # mise-missing gem (the exact rel-20260708-32701b failure) would slip past the
  # check and only blow up mid-suite as a raw GemNotFound. argv is unchanged; the
  # pin rides as the env overlay (gate_env), so bin/bundle's shebang resolves
  # to mise.
  bundle = suite_bundle_argv(path)
  label  = bundle.join(" ")
  _, ok = sh(*bundle, "check", chdir: path, capture: true, env: gate_env(repo, role: role))
  return if ok

  say("  #{repo}: bundle unsatisfied under the suite ruby — #{label} install")
  _, ok = sh(*bundle, "install", chdir: path, env: gate_env(repo, role: role))
  return if ok

  boot_ruby = suite_ruby(repo, path)
  here_ruby = RbConfig.ruby
  divergence =
    if boot_ruby == here_ruby
      ""
    else
      " Toolchain mismatch: the suite boots #{boot_ruby} but this conductor runs #{here_ruby} — " \
      "divergent gem homes (brew-vs-mise), so a shell-side `bundle check` can lie about the suite's env."
    end
  abort!("#{role} workspace #{repo}: the bundle is unsatisfied under the SUITE ruby (#{boot_ruby}) and " \
         "`#{label} install` failed.#{divergence} This is an ENV/toolchain issue, NOT a release " \
         "regression — nothing to eject or revert. Fix the bundle (cd #{path} && #{label} install), " \
         "then re-run.")
end

# --- the isolated gate workspace --------------------------------------------
# Materialize the PRIVATE checkout a gate suite runs in, pinned (detached) at
# `sha`, and return its path. See Release::GateWorkspace for the full why; the
# short version: the gate used to run its multi-minute, LAZILY-AUTOLOADING suite
# on the SHARED primary, so any concurrent `git checkout` (another agent session,
# a hand-run command — the flock only binds other bin/release invocations) tore
# the code snapshot mid-run and the gate false-failed on green code. A worktree
# nobody else knows about cannot be flipped underneath the suite.
#
# The workspace PERSISTS between runs (reset --hard onto the new SHA) so the
# bundle and the test DB stay warm; it is rebuilt from scratch when it's missing
# or its git metadata went stale (e.g. someone removed it by hand).
def gate_workspace!(repo, sha, role: "gate")
  primary = repo_path(repo)
  path    = Release::GateWorkspace.path(primary, role: role)
  sha     = sha.to_s.strip
  abort!("#{role} #{repo}: no SHA to pin the isolated #{role} checkout at") if sha.empty?

  if File.exist?(File.join(path, ".git"))
    # Reuse: hard-reset the worktree onto the SHA under test. `reset --hard` (not
    # `checkout`) so a half-written tree from a killed run can't refuse the move;
    # detached HEAD means we never contend with the primary or an agent worktree
    # for a branch name.
    _, ok = sh("git", "-C", path, "reset", "--hard", sha, capture: true)
    unless ok
      say("  #{repo}: the #{role} workspace is stale — rebuilding it")
      sh("git", "-C", primary, "worktree", "remove", "--force", path, capture: true)
      sh("git", "-C", primary, "worktree", "prune", capture: true)
    end
  end

  unless File.exist?(File.join(path, ".git"))
    FileUtils.mkdir_p(File.dirname(path))
    # ALWAYS prune first: a workspace dir deleted by hand stays REGISTERED in
    # .git/worktrees, and `worktree add` then refuses the path as already in use.
    # Pruning drops those orphan registrations; it never touches a live worktree.
    sh("git", "-C", primary, "worktree", "prune", capture: true)
    _, ok = sh("git", "-C", primary, "worktree", "add", "--detach", path, sha, capture: true)
    unless ok
      abort!("#{role} #{repo}: could not create the isolated #{role} checkout at #{path} " \
             "(`git worktree add --detach #{short(sha)}`). This is an ENV issue, NOT a release " \
             "regression — nothing to eject or revert.")
    end
  end

  # Drop untracked leftovers from the previous SHA — a since-deleted test file
  # would otherwise still be collected by the runner and fail on a missing
  # constant. NO `-x`, so GITIGNORED paths are kept untouched by definition: the
  # warm caches this workspace exists to preserve (tmp/ bootsnap, node_modules,
  # app/assets/builds) and the .env below are all gitignored, so they survive
  # without needing `-e` excludes (which would be pure no-ops here).
  sh("git", "-C", path, "clean", "-fd", capture: true)

  # The suite reads dotenv's `.env`, which is GITIGNORED — so a virgin worktree
  # has none and the suite would boot with a different env than the primary's
  # (and than CI's, which supplies its own). bin/agent-worktree copies it into
  # every worktree it creates for exactly this reason; the gate workspace is no
  # different. MIRRORED (copy, else delete) rather than merely copied: if the
  # primary drops its .env, a stale copy here would otherwise outlive it forever
  # and the gate would keep certifying against an env nothing else has.
  env_source = File.join(primary, ".env")
  env_target = File.join(path, ".env")
  if File.exist?(env_source)
    FileUtils.cp(env_source, env_target)
  elsif File.exist?(env_target)
    FileUtils.rm_f(env_target)
  end

  # …but NEVER a worktree-style `.env.test.local`. dotenv auto-loads it for
  # RAILS_ENV=test and it sets TEST_DATABASE_URL — which the hub's database.yml
  # renders into an explicit `url:`, BEATING the gate's own DATABASE_URL overlay.
  # A stray one here would silently point the gate's suite (and its PURGING
  # db:test:prepare) at some worktree's database. The privacy assertion would
  # catch it and abort, but the gate should not depend on that: remove it.
  FileUtils.rm_f(File.join(path, ".env.test.local"))

  path
end

# Bring the gate workspace to a runnable state: the right gems, a test DB that is
# the GATE'S OWN (never the primary's shared `<app>_test`, which a concurrent suite
# can pollute mid-run — the third false-negative mechanism), and a PREPARED TEST ENV
# (`test:prepare` — the hook that builds gitignored assets). Both rake tasks in ONE
# boot: `db:test:prepare` is exactly what CI runs before its suite
# (.github/workflows/ci.yml), so the gate's setup and CI's stay one command.
#
# WHY `test:prepare` MUST BE THE GATE'S JOB and not Rails' (regression, 2026-07-12):
# Rails runs `test:prepare` itself — the hook `tailwindcss-rails` enhances to build
# the gitignored app/assets/builds/tailwind.css — ONLY when no argument looks like a
# PATH (railties test_command.rb: `run_prepare_task if args.none?(EXACT_TEST_ARGUMENT_PATTERN)`).
# `db:test:prepare` does NOT build it. The satellites register a PATH-ARG gate command
# (`bin/rails test test/integration`), and this workspace is made by `git worktree add
# --detach` — which does NOT copy gitignored files, so it is VIRGIN. Result: the asset
# was never built, every view-rendering test died with `The asset "tailwind.css" is not
# present in the asset pipeline`, and the gate went RED on GREEN code while handing out
# EJECT/REVERT guidance. (Driven on turf-monster: 86 runs, 43 errors, all that one.)
#
# So the GATE prepares the env, for ANY registered command shape — argless or path-arg.
# The alternative (rewrite each satellite's registry command to be argless) leaves the
# gate silently assuming a shape, which is a trap for the next person to register a
# lane — and is precisely how this bug got in. Preparing an argless lane's env too is
# idempotent; one code path beats a shape-aware one. (The ship role reuses this same
# prep — same reasoning, its own workspace.)
def prepare_gate_workspace!(repo, path, role: "gate")
  ensure_suite_bundle!(repo, path, role: role)

  # PROVE the DB is private BEFORE db:test:prepare — that task PURGES and reloads
  # the schema, so running it against a database we merely ASSUME is ours would
  # destroy a concurrent suite's data. Assert first, destroy second.
  assert_private_gate_db!(repo, path, role: role)

  out, ok = sh("bin/rails", "db:test:prepare", "test:prepare", chdir: path, capture: true, env: gate_env(repo, role: role))
  return if ok

  # An env-class abort — NEVER a red suite. A workspace that cannot build its assets
  # would fail every view-rendering test, and routing that into the "a regression is
  # riding origin/release" path is how a good PR (#498) nearly got ejected.
  #
  # But be honest in BOTH directions: `tailwindcss:build` also fails on a broken
  # stylesheet IN the release's own diff (a bad `@apply`, an unknown utility, a
  # malformed `@theme`). So this reports a LIKELIHOOD, not a verdict — and prints the
  # captured output, which is the only thing that actually tells the two apart.
  abort!("#{role} #{repo}: `bin/rails db:test:prepare test:prepare` failed in the isolated #{role} workspace " \
         "(#{path}, #{gate_database_url(repo, role: role) || 'file-backed test DB inside the workspace'}). The #{role} " \
         "never reached the suite, so this is NOT a release regression — nothing to eject or revert.\n" \
         "This is USUALLY an ENV gap (Postgres down; a missing asset toolchain) — BUT `test:prepare` " \
         "builds the app's stylesheet, so a BROKEN STYLESHEET in the release's own diff (a bad `@apply`, " \
         "an unknown utility, a malformed `@theme`) fails here too. Read the output below to tell which: " \
         "an env gap needs a fix on this host, a broken stylesheet needs a fix on `#{RELEASE_BRANCH}`.\n" \
         "#{indent_output(out)}")
end

# The tail of a failed command's captured output, indented so it reads as evidence
# under an abort rather than as more prose. Capped: the abort should show the operator
# the error, not replay an entire rake log at them.
def indent_output(out, lines: 25)
  text = out.to_s.strip
  return "  (no output captured)" if text.empty?

  kept = text.lines.last(lines).map { |l| "  #{l.rstrip}" }.join("\n")
  text.lines.size > lines ? "  … (#{text.lines.size - lines} earlier lines omitted)\n#{kept}" : kept
end

# Boot the app in the gate workspace and read back the database it ACTUALLY
# connects to in the test env — then REFUSE to run unless that DB is private to
# this gate (Release::GateWorkspace.private_db?).
#
# WHY, and why asserting the DB NAME STRING would not do: the "private test DB" is
# delivered by an ENV overlay, and an env var only lands if the app's
# config/database.yml actually reads it. `TEST_DATABASE_URL` is a HAND-ROLLED seam
# — the hub renders `url: <%= ENV["TEST_DATABASE_URL"] %>`; turf-monster does NOT
# (bare `database: turf_monster_test`). So for turf the overlay was silently
# INERT: the gate would have run — and `db:test:prepare` would have PURGED — the
# SHARED primary test DB. `DATABASE_URL` (a Rails builtin) now covers every app,
# but a guarantee that rests on every future app's config being right is a
# CONVENTION, not an invariant. This makes it an invariant: ask the booted app,
# and treat a shared DB as a hard abort — never a silent stomp.
def assert_private_gate_db!(repo, path, role: "gate")
  probe = 'print "GATEDB=#{ActiveRecord::Base.connection_db_config.database}"'
  out, ok = sh("bin/rails", "runner", probe, chdir: path, capture: true, env: gate_env(repo, role: role))
  # capture: true merges stderr (bundler/rubygems warnings), so pluck the token
  # instead of trusting the whole stream.
  resolved = out.to_s[/GATEDB=(.*)$/, 1].to_s.strip

  if !ok || resolved.empty?
    abort!("#{role} #{repo}: could not resolve the test database in the #{role} workspace (#{path}) — " \
           "`bin/rails runner` failed to boot. This is an ENV issue, NOT a release regression — " \
           "nothing to eject or revert.")
  end

  if Release::GateWorkspace.private_db?(resolved: resolved, repo: repo, workspace: path, role: role)
    say("  #{repo}: #{role} test DB #{resolved} (private to this #{role})")
    return
  end

  abort!("#{role} #{repo}: the suite would run against `#{resolved}` — a SHARED test database, NOT this " \
         "#{role}'s own (#{Release::GateWorkspace.test_database_name(repo, role: role)}). REFUSING: the next step " \
         "(`db:test:prepare`) PURGES it, which would destroy a concurrent suite's data, and a shared " \
         "DB re-opens the cross-talk the isolated workspace exists to close. CAUSE: #{repo}'s " \
         "config/database.yml is not honouring the workspace's DATABASE_URL/TEST_DATABASE_URL overlay for " \
         "the test env. This is an ENV/config issue, NOT a release regression — nothing to eject or revert.")
end

# The gate DB URL for this repo, or nil when its test DB is already file-backed
# INSIDE the workspace (SQLite — private by construction, and a postgres URL would
# be a live trap). Memoized: it reads the app's config/database.yml.
def gate_database_url(repo, role: "gate")
  @gate_database_url ||= {}
  key = [repo, role]
  return @gate_database_url[key] if @gate_database_url.key?(key)

  @gate_database_url[key] = Release::GateWorkspace.database_url_for(repo, repo_path(repo), role: role)
end

# --- system-tier browser guard ----------------------------------------------
# The hub's gate command carries the SYSTEM tier (`test:system` — see
# config/release_repos.yml), and system tests drive a real headless Chrome. On a
# host with no Chrome, Selenium fails INSIDE the suite: the runner exits non-zero
# with a driver error, which the gate would otherwise read as a RED SUITE and hand
# the operator eject/revert guidance — ejecting a perfectly good PR for a missing
# browser. That misattribution is the exact class of failure the isolated gate was
# rebuilt to end, so the browser is asserted UP FRONT and, when absent, fails in
# the ENV class with the same wording as the bundle/DB guards.
#
# Only asserted when the registered command actually runs the tier, so the
# integration-subset satellites never need a browser on the gate host.
#
# "owner/repo" for a repo's origin remote (the gh api path), or "" when the remote
# isn't GitHub — which CiStatus reads as no data, never as a red.
def repo_name_with_owner(repo)
  out, ok = sh("git", "-C", repo_path(repo), "remote", "get-url", "origin", capture: true)
  ok ? CiStatus.name_with_owner(out) : ""
end

# GitHub CI's verdict for ONE commit. RELEASE_CI_STATUS injects it (a bare token or
# a raw check-runs payload), so the meta-tests never touch the network — and an
# injected verdict skips the remote lookup entirely. Best-effort by construction:
# an auditor that RAISES must never fail a gate that passed.
def ci_verdict(repo, sha)
  injected = ENV["RELEASE_CI_STATUS"].to_s
  nwo = injected.empty? ? repo_name_with_owner(repo) : ""
  CiStatus.for_sha(nwo, sha, injected)
rescue StandardError => e
  { state: :unverified, reason: e.message.to_s[0, 140] }
end

# The G3 CREDIT probe (task dedupe-hub-release-suite): does this exact SHA already
# carry a COMPLETED green conclusion that the still-pending runs merely duplicate?
# Green-with-source when it does (CiStatus.credit_for_sha), nil for everything
# else. Same injection seam as ci_verdict; only consulted after
# fast_forward_promote? proved origin/#{RELEASE_BRANCH} IS the accepted head CI
# already built. Best-effort BY DESIGN and fail-CLOSED into the NORMAL path: nil —
# including any read/parse fault — sends the caller to poll_ci_verdict, so a probe
# that cannot see never certifies and never blocks.
def ci_credit_verdict(repo, sha)
  injected = ENV["RELEASE_CI_STATUS"].to_s
  nwo = injected.empty? ? repo_name_with_owner(repo) : ""
  CiStatus.credit_for_sha(nwo, sha, injected)
rescue StandardError
  nil
end

# The G3 TREE credit (task dedupe-hub-release-suite, round 2): the LIVE promote is
# a batch-PR `gh pr merge --merge`, which mints a NEW merge-commit SHA — so the
# same-SHA credit above never fires on the normal path (the review block that
# rebuilt this). But that merge commit usually SNAPSHOTS THE IDENTICAL TREE as the
# accepted head (true whenever `accepted` was not behind `release` — e.g.
# promotion #582: accepted 5b10402d and release cf93bab6 share tree 5b1c78e0), and
# GitHub CI checks out CONTENT, not history: a completed green earned on the
# accepted head certifies the exact tree the release merge re-runs. So when
# tree_identical_promote proved the trees equal, this reads the ACCEPTED HEAD's
# own verdict and credits ONLY a completed :green (ci_pass?, the gate's one pass
# state). Everything else — the accepted run red, still pending, missing,
# unreadable, unverified — returns nil and the caller polls the release SHA
# exactly as today (strict fall-through; a red is never re-read, a pending
# evidence run is a genuine wait). The credited note records BOTH full SHAs + the
# shared tree so the audit trail shows precisely which run vouched for which
# commit. Best-effort like ci_credit_verdict: a probe that raises credits nothing.
def ci_tree_credit_verdict(repo, release_sha, promote)
  ci = ci_verdict(repo, promote[:accepted_sha])
  return nil unless ci_pass?(ci)

  { state: :green, count: ci[:count],
    credited: "tree-identical promote — #{ACCEPTED_BRANCH} head #{promote[:accepted_sha]} concluded green and " \
              "shares tree #{promote[:tree]} with #{RELEASE_BRANCH} #{release_sha}; the release-push run " \
              "re-executes an identical tree" }.compact
rescue StandardError
  nil
end

# Was the accepted→release promote a FAST-FORWARD — origin/#{RELEASE_BRANCH}
# resting on the SAME commit as origin/#{ACCEPTED_BRANCH}? Only then may the
# pre-QA gate credit an existing conclusion: the release tip IS the accepted head
# whose check-runs the PR/accepted seam already produced, so a green there proves
# THIS tree. (The batch-PR promote mints a merge commit — a NEW SHA with fresh
# check-runs — and never satisfies this.) The same-SHA discipline mirrors
# Release::ShipSequence.ship_gate_skip?, which self-skips G4 only against G3's
# record for the identical frozen SHA. An unresolvable accepted ref answers false
# (no credit, normal poll) — never an abort.
def fast_forward_promote?(path, release_sha)
  return false if release_sha.to_s.empty?

  out, ok = sh("git", "-C", path, "rev-parse", "origin/#{ACCEPTED_BRANCH}", capture: true)
  ok && out.strip == release_sha.to_s
end

# Did the batch-PR promote mint a merge commit whose TREE is the accepted head's
# tree — a different SHA snapshotting IDENTICAL content? That is the LIVE promote
# shape (`gh pr merge --merge`), and it holds whenever `accepted` was not behind
# `release` at merge time — the common case. It BREAKS whenever release carries
# commits accepted lacks: above all the consumer lock-bump commits `bin/release
# prepare` lands on `release` when a gem rides (publish-gems-before-qa, PR #588 —
# its step 4c commits the bump BEFORE pre_qa_gate resolves origin/release, so the
# SHA read here is the post-bump one and its tree no longer matches accepted's).
# Then this answers nil, the credit refuses, and the gate polls the post-bump SHA
# exactly as today — the cross-PR contract pinned on #588, asserted by the
# lock-bump interaction test in release_cli_test.
#
# Answers {accepted_sha:, tree:} ONLY when both trees resolve and match and the
# SHAs DIFFER (the same-SHA case is fast_forward_promote?'s, checked first).
# Every git fault — an unresolvable ref, a failed rev-parse — answers nil: no
# credit, normal poll, never an abort.
def tree_identical_promote(path, release_sha)
  return nil if release_sha.to_s.empty?

  accepted, ok = sh("git", "-C", path, "rev-parse", "origin/#{ACCEPTED_BRANCH}", capture: true)
  return nil unless ok

  accepted = accepted.strip
  return nil if accepted.empty? || accepted == release_sha.to_s

  release_tree, rel_ok = sh("git", "-C", path, "rev-parse", "#{release_sha}^{tree}", capture: true)
  accepted_tree, acc_ok = sh("git", "-C", path, "rev-parse", "#{accepted}^{tree}", capture: true)
  return nil unless rel_ok && acc_ok

  release_tree = release_tree.strip
  return nil if release_tree.empty? || release_tree != accepted_tree.strip

  { accepted_sha: accepted, tree: release_tree }
end

# The verdict pair, persisted: what CI said about the SHA the gate certified.
# `credited` names the credited source when the G3 gate credited an existing green
# conclusion instead of awaiting a duplicate run (ci_credit_verdict) — absent on
# every polled verdict, so the audit trail distinguishes the two.
def ci_gate_record(ci)
  record = { "state" => ci[:state].to_s }
  checks = (Array(ci[:failing]) + Array(ci[:pending])).map(&:to_s)
  record["checks"] = checks if checks.any?
  record["count"] = ci[:count].to_i if ci[:count]
  record["reason"] = ci[:reason].to_s if ci[:reason]
  record["credited"] = ci[:credited].to_s if ci[:credited]
  record
end

# THE GATE VERDICT, fail-CLOSED. Since DevOps v2 Phase 3 (promote-ci-to-gate-verdict)
# GitHub CI's conclusion for a SHA IS the G3/G4 verdict — no longer an auditor's
# footnote beside a local suite. So this passes on EXACTLY ONE state (:green) and
# fails closed on every other, red AND every no-data/pending state alike
# (none/pending/unverified/unreadable/no_pr/closed/merged) — there is deliberately
# NO second "unknown ⇒ pass" branch. A false green here would deploy an untested SHA
# to QA (G3) or ship it to production (G4), so an absent/unknown/red verdict must
# never read as certified. nil or a non-Hash is green-less ⇒ false.
def ci_pass?(ci)
  ci.is_a?(Hash) && ci[:state] == :green
end

# The poll DECISION for the pre-QA CI gate, factored PURE so it is unit-testable on
# its own — the CI-verdict analogue of Release::ShipSequence.run_watch_verdict. Given
# ONE ci_verdict Hash it says whether the gate can decide now or must keep polling:
#   :pass  — a GREEN conclusion certifies the SHA (the ONLY pass; ci_pass? green).
#   :abort — a TERMINAL non-green that waiting can NEVER turn green, so the gate stops
#            polling and fails closed at once:
#              * :red        — a regression is riding origin/#{RELEASE_BRANCH} (the
#                              eject/revert recovery), and
#              * :unreadable — a token/credential fault; polling a refused token only
#                              burns the whole timeout and never heals it mid-sweep.
#   :wait  — CI has NOT concluded yet: :none (no run registered), :pending (the push
#            run is still building — the raw queued/in_progress/waiting statuses all
#            fold to :pending), :unverified (a transient read miss), or anything else
#            not-yet-green. THIS is the just-merged-SHA case that used to abort the
#            sweep's first run: the caller HOLDS and re-reads until green, a terminal
#            abort, or the timeout — then it fails CLOSED on the last verdict read.
def ci_poll_action(ci)
  return :pass if ci_pass?(ci)

  state = ci.is_a?(Hash) ? ci[:state] : nil
  return :abort if %i[red unreadable].include?(state)

  :wait
end

# A one-line CI verdict detail for a gate message: "state" or "state: reason".
def ci_detail(ci)
  state  = ci.is_a?(Hash) ? ci[:state].to_s : ""
  reason = ci.is_a?(Hash) ? ci[:reason].to_s : ""
  reason.empty? ? state : "#{state}: #{reason}"
end

# Stamp what the G3 pre-QA gate actually CERTIFIED for a repo: the SHA it ran on
# and the command it ran. G4's ship gate skips its own suite ONLY against this
# record (Release::ShipSequence.ship_gate_skip?) — never against the registry or
# the deployed SHA, neither of which proves a suite ever ran.
#
# It also carries the CI verdict for the same SHA (`ci: {state, checks}`, plus
# `count`/`reason` when GitHub gave them). Since DevOps v2 Phase 3 that verdict is no
# longer a footnote beside a local suite — it is what `ok` was DERIVED from
# (ci_pass?), so the pair is the whole audit: what CI concluded, and the gate result
# it produced.
#
# `ok` is now a PARAMETER (was hardcoded true): a GREEN CI records ok:true and lets
# G4 self-skip (ship_gate_skip?); a non-green G3 records ok:FALSE — a red gate must
# be recorded as failed, never silently un-stamped — and then aborts (fail-closed).
#
# Best-effort like the other record steps: a board hiccup must not fail a GREEN
# gate. A missing green record makes G4 re-derive the verdict from CI on the frozen
# SHA (never a self-skip), so the worst case of a lost stamp is a redundant CI read,
# never an unguarded ship.
def record_qa_gate(rel_slug, repo, sha, cmd, ci = nil, ok = true)
  return if rel_slug.to_s.empty? || DRY

  ci_arg = ci ? ", ci: #{ci_gate_record(ci).inspect}" : ""
  conductor(
    "r = Release.find_by(slug: #{rel_slug.to_s.inspect}); " \
    "Release::Conductor.record_qa_gate(release: r, repo: #{repo.to_s.inspect}, " \
    "sha: #{sha.to_s.inspect}, cmd: #{cmd.to_s.inspect}, ok: #{ok ? 'true' : 'false'}#{ci_arg}) if r; " \
    "puts({ qa_gate: #{repo.to_s.inspect} }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ G3 certification not recorded for #{repo} (#{e.message}) — the ship gate will re-run the " \
      "suite on the frozen SHA rather than skip it (fail-open)")
end

# The G3 fail-closed abort text, chosen by the state the gate STOPPED on:
#   * :red        — a regression riding origin/#{RELEASE_BRANCH}: the eject/revert recovery.
#   * :unreadable — a credential/token fault the gate did NOT poll (a refused token never
#                   heals mid-sweep), so it aborts on the first read with the remedy.
#   * else        — a :pending/:none/:unverified verdict that never reached green before
#                   the poll timed out: let CI finish and re-run. None is ever a pass.
def pre_qa_ci_abort(repo, sha, ci)
  case ci[:state]
  when :red
    named = Array(ci[:failing]).join(", ")
    "pre-QA gate FAILED for #{repo}: GitHub CI called #{short(sha)} RED#{named.empty? ? '' : " (#{named})"} — a " \
      "regression is riding origin/#{RELEASE_BRANCH}. Identify the offending task, eject it " \
      "(`bin/release eject <task> --feedback \"…\"`), revert its merge commit on `#{RELEASE_BRANCH}` " \
      "(git revert -m 1 <merge-sha>; push), then re-run `bin/release prepare` — the sweep self-heals and the " \
      "REST of the RC rides on."
  when :unreadable
    "pre-QA gate FAILED for #{repo}: GitHub CI is UNREADABLE for #{short(sha)} (#{ci_detail(ci)}). CI is the G3 " \
      "verdict now and FAILS CLOSED — an :unreadable verdict is a credential/token fault, NOT a missing or still-" \
      "running CI, so the gate does NOT poll it (a refused token never heals mid-sweep). " \
      "#{CiStatus.unreadable_remedy(repo_name_with_owner(repo), cause: ci[:cause])}"
  else
    "pre-QA gate HELD for #{repo}: GitHub CI reached NO green verdict for #{short(sha)} (#{ci_detail(ci)}) before " \
      "the poll timed out. CI is the G3 verdict now and FAILS CLOSED on anything but green — a still-pending or " \
      "absent verdict never certifies a SHA. The gate POLLED origin/#{RELEASE_BRANCH} until ~#{ci_poll_timeout}s " \
      "elapsed; let CI conclude (or widen RELEASE_CI_POLL_TIMEOUT), then re-run `bin/release prepare`."
  end
end

# Seconds between CI verdict re-reads, and the outer wall-clock bound on the whole
# poll. The defaults cover a full release-CI run (the same suite PR CI runs) with
# headroom; BOTH are ENV-overridable so an operator can widen the window on a slow
# runner — or a test collapse it to a single read (timeout 0) — without touching code.
def ci_poll_interval = ENV.fetch("RELEASE_CI_POLL_INTERVAL", "15").to_i
def ci_poll_timeout  = ENV.fetch("RELEASE_CI_POLL_TIMEOUT", "1200").to_i

def monotonic_s = Process.clock_gettime(Process::CLOCK_MONOTONIC)

# POLL GitHub CI's verdict for `sha` until it CONCLUDES, mirroring
# dispatch_and_watch / run_concluded_success?. Since DevOps v2 Phase 3 Slice 3 made CI
# the G3 verdict, reading it ONCE aborted every sweep's first run: the sweep merges to
# origin/#{RELEASE_BRANCH}, CI STARTS on that fresh SHA, and the gate read it :pending and
# held — forcing a manual "wait for release CI to conclude, then re-run bin/release
# prepare" round-trip (observed @ 015241f and @ f05cdf5). So a :wait verdict now HOLDS
# and re-reads every ci_poll_interval seconds until CI concludes (:green/:red) or
# ci_poll_timeout elapses, instead of failing closed on the first pending read.
#
# STILL FAIL-CLOSED, exactly as the single read was (ci_poll_action owns the split): a
# :red or :unreadable verdict returns AT ONCE — a regression riding the branch, or a
# token fault polling cannot fix — and a timeout returns the LAST still-pending verdict,
# never a fabricated green. The caller runs ci_pass? on the returned Hash, so ONLY a
# genuine :green certifies; every other outcome aborts the gate.
def poll_ci_verdict(repo, sha)
  timeout    = ci_poll_timeout
  interval   = ci_poll_interval
  deadline   = monotonic_s + timeout
  last_state = nil
  ci = nil
  loop do
    ci = ci_verdict(repo, sha)
    return ci unless ci_poll_action(ci) == :wait

    remaining = deadline - monotonic_s
    if remaining <= 0
      say("  #{repo}: CI still #{ci[:state]} for #{short(sha)} after ~#{timeout}s — poll timed out, failing closed")
      return ci
    end
    if ci[:state] != last_state
      say("  #{repo}: CI #{ci[:state].to_s.upcase} for #{short(sha)} — holding for it to conclude " \
          "(re-reading every #{interval}s, up to ~#{timeout}s; set RELEASE_CI_POLL_TIMEOUT to widen)")
    end
    last_state = ci[:state]
    sleep([interval, remaining].min)
  end
end

def pre_qa_gate(app_groups, rel_slug = nil)
  say("")
  # The banner names what THIS step does now (DevOps v2 Phase 3): it reads GitHub
  # CI's verdict for each app's origin/#{RELEASE_BRANCH} SHA. The local suite that
  # used to run in an isolated gate workspace is DEMOTED — CI is the verdict — so the
  # registered qa_test_cmd is still RECORDED for the G4 drift check, just not executed.
  step("pre-QA gate: GitHub CI's verdict for each app's origin/#{RELEASE_BRANCH} SHA " \
       "(before any QA deploy)")
  app_groups.each do |group|
    repo = group["repo"]
    cmd  = qa_gate_cmd(repo)
    if cmd.empty?
      say("  #{repo}: no qa_test_cmd registered — self-gates (suite runs at ship / its own deploy); skip")
      next
    end
    # Validate the registry command even though the suite is DEMOTED (Phase 3): a
    # malformed value must still abort a preview, and it is recorded for the G4 drift
    # check below, so it may not be garbage. test_cmd_argv aborts on an unbalanced quote.
    test_cmd_argv(cmd)
    if DRY
      say("  [dry-run] pre-QA gate #{repo}: GitHub CI verdict for origin/#{RELEASE_BRANCH} " \
          "(#{cmd} recorded for the G4 drift check, not run)")
      next
    end

    path = repo_path(repo)
    abort!("app repo not found at #{path} — clone it as a sibling at the projects root") unless Dir.exist?(path)
    sh("git", "-C", path, "fetch", "origin", "--quiet")
    out, ok = sh("git", "-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}", capture: true)
    abort!("could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the pre-QA gate — fetch, then re-run") unless ok
    sha = out.strip

    # DevOps v2 Phase 3+4: the pre-QA suite no longer runs on the conductor's machine.
    # GitHub CI's verdict for this exact origin/#{RELEASE_BRANCH} SHA IS the gate now
    # (poll_ci_verdict -> ci_pass?), so the whole local-cert flakiness class (a lazily-
    # autoloaded suite torn by a concurrent checkout) retired with it.

    # G3 DEDUPE (task dedupe-hub-release-suite): the hub registers the same full
    # suite at the accepted seam (the batch PR's pull_request run on the accepted
    # head) and again on the release push (the promote's merge commit), so every
    # sweep re-runs — and the poll below waits out — checks an IDENTICAL TREE
    # already earned. Two credits, tried in order, both fail-closed into the poll:
    #   1. SAME-SHA (fast_forward_promote?): origin/#{RELEASE_BRANCH} IS the
    #      accepted head — its own completed greens cover the pending duplicates
    #      (ci_credit_verdict). The true-FF shape; rare under the batch-PR merge.
    #   2. SAME-TREE (tree_identical_promote): the LIVE shape — the batch-PR merge
    #      minted a NEW SHA whose tree EQUALS the accepted head's, so the accepted
    #      head's completed green vouches for the identical content
    #      (ci_tree_credit_verdict; both SHAs + the shared tree recorded).
    # NOTHING else changed: a non-credit — red, a genuinely still-running suite,
    # missing checks, diverged trees (e.g. a consumer lock-bump commit riding
    # #{RELEASE_BRANCH} — see tree_identical_promote) — falls through to the exact
    # same poll below.
    credit = fast_forward_promote?(path, sha) ? ci_credit_verdict(repo, sha) : nil
    if credit
      credit[:credited] = "#{credit[:credited]}; fast-forward promote — " \
                          "origin/#{RELEASE_BRANCH} is the #{ACCEPTED_BRANCH} head CI already built"
    elsif (promote = tree_identical_promote(path, sha))
      credit = ci_tree_credit_verdict(repo, sha, promote)
    end
    if credit
      say("  #{repo}: crediting the existing green conclusion for #{short(sha)} — no duplicate run awaited " \
          "(#{credit[:credited]})")
    end

    # THE VERDICT: GitHub CI's conclusion for the SHA under test, POLLED until it
    # concludes (poll_ci_verdict) and fail-CLOSED via ci_pass? — only :green certifies.
    # A red (a regression riding origin/#{RELEASE_BRANCH}) or an :unreadable token fault
    # aborts at once; a still-:pending/:none/:unverified verdict is HELD — a just-merged
    # SHA's CI is still building — until it goes green, red, or the poll times out. This
    # replaces the single read that aborted every sweep's first run on a pending CI.
    ci = credit || poll_ci_verdict(repo, sha)
    ok = ci_pass?(ci)
    step("pre-QA gate #{repo}: GitHub CI #{ci[:state].to_s.upcase}#{credit ? ' (credited)' : ''} @ #{short(sha)} " \
         "(#{cmd} recorded for the G4 drift check, not run here)")

    # Certify — the ONLY evidence G4 accepts for skipping its own gate. Recorded for
    # GREEN and non-green alike: a red G3 records ok:FALSE (it must not silently skip
    # recording), carrying CI's verdict for the audit trail.
    record_qa_gate(rel_slug, repo, sha, cmd, ci, ok)
    next if ok

    abort!(pre_qa_ci_abort(repo, sha, ci))
  end
end

def prepare
  task_slugs = opt_values("--task")
  slug = opt_value("--slug")

  say("Prepare release — Steffon qa-deploy (self-healing)#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!
  # On the prod default a non-dry prepare fires a REAL accepted→release batch merge +
  # a REAL `bin/qa-server deploy`, so gate it like `ship` does. confirm returns true
  # under --yes (hands-off) and --dry-run (previews nothing-executed).
  return unless confirm("Prepare the current release — sweep reviewed work onto `#{RELEASE_BRANCH}` + deploy QA?")

  # Deploy-lane narration: Steffon owns the whole middle — sweep, QA deploy, and
  # the QA-green flip. Open a role activity so the heartbeat attributes this phase to
  # him (matching the board's stage timeline). Best-effort — see the narrate
  # helpers. `steffon_span` gates the close in the rescue so an abort BEFORE this
  # point never emits a stray `end`.
  open_role_span("steffon", "sweep → deploy RC to QA")
  steffon_span = true

  # 1. DETECT (a read — runs even in --dry-run): the reviewed queue + assembled
  #    stragglers with their PR/merged state, the review-gate screen, and the
  #    current release. `--task` narrows the sweep (operator curation).
  step("record (read-only): Release::Conductor.sweep_candidates + screen")
  detect = conductor(sweep_detect_ruby(task_slugs), read_only: true)
  cands  = detect["tasks"] || []
  active = detect["release"]

  # 1b. --task is operator CURATION: every NAMED slug must survive detection. A
  #     typo'd or ineligible slug (not `reviewed`, not an `assembled` straggler)
  #     is filtered out BEFORE the screen ever sees it, so without this check it
  #     would drop silently and the run could still end "✓" — a false success.
  #     Fail loudly BEFORE anything merges or deploys.
  if task_slugs.any?
    missing = task_slugs - cands.map { |c| c["slug"] }
    if missing.any?
      abort!("--task slug(s) not sweepable: #{missing.join(', ')} — not in the reviewed queue or the " \
             "assembled stragglers (typo? not yet `reviewed`?). Nothing was merged or deployed; " \
             "fix the slug (or review the task), then re-run `bin/release prepare`.")
    end
  end

  # 2. IDEMPOTENT NO-OP: nothing to sweep and nothing in flight → report + stop
  #    (exit 0), never fabricate work. An ACTIVE release with no new candidates
  #    falls through — that's the self-healing re-run (deploy + flip what's
  #    already swept).
  if cands.empty? && active.nil?
    say("")
    say("✓ Nothing to prepare — no reviewed work, no assembled stragglers, no active release (idempotent no-op).")
    close_role_span("qa-deploy no-op — nothing to prepare")
    return
  end
  cands.each do |c|
    at = c["merged"].to_s.empty? ? "" : " · merged: #{c['merged']}"
    say("  sweep #{c['slug']} (#{c['stage']}#{at}) · #{c['repo']} · #{c['pr_url']}")
  end

  # 2b. Review gate over the sweep list — defense-in-depth. Auto-detected
  #     candidates are sweepable by construction (reviewed/assembled), and a
  #     --task slug that ISN'T a candidate already failed loudly at 1b (the
  #     screen only ever sees surviving slugs, so it can't catch a dropped one).
  #     prepare has NO --override — use `bin/release merge --override` for an
  #     audited bypass, then re-run prepare.
  enforce_review_gate!(detect["screen"] || {}) if cands.any?

  # 3. SWEEP PLAN (pure: Release::SweepPlan): partition the candidates into the
  #    members to RECORD onto the RC (code on accepted/release/main) and the HELD
  #    anomalies (a `reviewed` member with no merged stamp — review's feat→accepted
  #    merge never landed). Unlike the explicit `merge` command, a held member here
  #    is WARNED + left `reviewed` (it self-heals on re-review) — the self-healing
  #    sweep never aborts on it.
  plan = Release::SweepPlan.compute(cands)
  held = plan["held"]
  held.each do |s|
    say("  ⚠ #{s}: `reviewed` but merged:\"\" — review never landed its feat PR on `#{ACCEPTED_BRANCH}`; " \
        "left `reviewed` (re-review to heal)")
  end
  plan["record"].reject { |row| row["merged"] == ACCEPTED_MERGED }.each do |row|
    step("skip promote for #{row['slug']} — already merged: #{row['merged']} (crash recovery); membership still records")
  end

  # 4. PROMOTE accepted → release (the accepted-ladder's SECOND rung). Review already
  #    merged each feat PR into `accepted` (merged:"accepted"), so the sweep no longer
  #    merges N per-task feat PRs — it lands ALL of `accepted` onto `release` via ONE
  #    batch PR per repo (a single-repo release = exactly one PR). Git-FIRST (the
  #    irreversible step); the record write follows. Idempotent + fail-closed:
  #    accepted level with release → skip the PR but still record + deploy; a promote
  #    conflict / missing checkout ABORTS (members stay `reviewed` for a clean re-run).
  promote_repos = cands.select { |c| c["merged"].to_s == ACCEPTED_MERGED }
                       .map { |c| c["repo"].to_s }.reject(&:empty?).uniq
  promote_accepted_to_release!(promote_repos, label: slug) if promote_repos.any?

  # 5. Record membership for every member whose code is on accepted/release/main
  #    (plan["sweep"]) + the repo plan, in ONE `heroku run`. A `held` member is NOT
  #    in plan["sweep"], so it is never recorded onto the RC. Suppressed under
  #    --dry-run (the promotion previewed above; nothing recorded).
  landed = plan["sweep"]
  left_reviewed = held
  result = {}
  if landed.any? && !DRY
    step("record: Release::Conductor.sweep! ×#{landed.size} + repo plan in ONE run (#{landed.join(', ')})")
    result = conductor(batch_sweep_with_plan_ruby(landed, slug))
  end

  # 4b. No sweep write happened (dry-run, or a pure re-run with nothing new) →
  #     read the current release's plan read-only so the deploy half still runs.
  if (result["repos"] || []).empty?
    step("record (read-only): Release::Conductor.repo_plan(Release.current)")
    result = conductor(
      "r = Release.current; " \
      "puts((r ? { slug: r.slug, state: r.state, branch: r.branch, repos: Release::Conductor.repo_plan(r) } : {}).to_json)",
      read_only: true
    )
  end

  rel_slug = result["slug"] || slug || "rel-pending"
  repos    = result["repos"] || []
  if repos.empty?
    if DRY && cands.any?
      say("")
      say("✓ Dry run: #{cands.size} task(s) would sweep onto a fresh candidate — the repo plan (and the QA deploy preview) " \
          "becomes available once the sweep records; re-run without --dry-run.")
      close_role_span("qa-deploy dry-run — sweep previewed")
      return
    end
    say("")
    say("✓ Nothing to deploy — the release has no members yet" \
        "#{left_reviewed.any? ? " (#{left_reviewed.join(', ')} left `reviewed` — no code on `#{ACCEPTED_BRANCH}`)" : ''}.")
    close_role_span("qa-deploy no-op — no members to deploy")
    return
  end

  app_groups = repos.select { |g| g["kind"] == "app" }
  gem_groups = repos.select { |g| g["kind"] == "gem" }
  say("  release #{rel_slug} (#{result['state']}) · #{repos.size} repo(s): #{app_groups.size} app, #{gem_groups.size} gem")
  record_release_event(rel_slug, "assemble_release", "started")

  # 4c. PRODUCER-FIRST GEM PUBLISH + CONSUMER LOCK BUMP — BEFORE the pre-QA gate
  #     and any QA deploy (publish-gems-before-qa). TWO PHASES, because a
  #     RubyGems push can never be re-pushed: phase 1 VALIDATES every swept gem
  #     (fail-closed fetch, version parses, stranded-work guard, a swept
  #     consumer declares it) and aborts on ANY failure with ZERO gems
  #     published; only then does phase 2 publish and commit each consumer's
  #     Gemfile.lock bump onto its release branch. Ordering is load-bearing:
  #     the lock commits land BEFORE pre_qa_gate resolves origin/release, so
  #     the CI verdict targets the post-bump SHA, QA bundles the new lock, and
  #     prod ships the exact tree QA tested. Ship's publish stays as the
  #     idempotent verify (already-live → skip).
  gem_plan = validate_gems_for_qa(gem_groups, app_groups)
  bump_consumer_locks_for_qa(app_groups, publish_gems_for_qa(gem_plan))

  # 5. PRE-QA GATE — the prepare-owned test tier on origin/release, BEFORE any
  #    QA deploy. A regression aborts with eject guidance while every member is
  #    still `reviewed`; the rest of the RC rides on the re-run.
  #
  #    G3 CANDIDATE opens HERE (replacing the old review_tests started/completed
  #    bracket — prepare co-opting that stage bracket is what made the Tested
  #    column start AFTER Assembled on /deployments). The gate window spans the
  #    pre-QA suite, the QA deploys + boot smokes, and the post-deploy hooks;
  #    every test SOP inside it rides the close via the run_test_scope collector.
  #    Closed success beside qa_green!, failed at the boot-failure branch, and
  #    failed by the SystemExit wrapper below when anything in the window aborts.
  record_gate_open(rel_slug, "g3_candidate", actor: "steffon")
  g3_gate = :open
  pre_qa_gate(app_groups, rel_slug)

  # 5b. Record the Steffon assembled QA intent for every member so /deployments shows
  #     him QA-ing the RC live the moment the deploy half starts — the Deploy mirror
  #     of bin/reviewer-select's review intent (no more hand-run `bin/task intent
  #     --to assembled --actor steffon`). Swept members are still `reviewed` (the
  #     flip waits for QA-green), so record_deploy_intents! records the plain
  #     toward-`assembled` intent, superseded when qa_green! lands the flip; an
  #     already-`assembled` member (straggler/re-run) gets the qa-marked
  #     toward-`shipped` intent instead (see Release::Conductor#record_qa_intent).
  #     Append-only + idempotent. A board WRITE → suppressed in --dry-run
  #     (conductor prints the plan). BEST-EFFORT (record_deploy_intent): this
  #     cosmetic ticker write must never abort the QA deploy on a transient
  #     prod-board failure — it warns and continues.
  step("record: Steffon assembled QA intent (live crew ticker)")
  record_deploy_intent(
    "Steffon assembled QA intent",
    "r = Release.current; n = Release::Conductor.record_deploy_intents!(r, to_stage: 'assembled', actor: 'steffon'); " \
    "puts({ intent: 'assembled', actor: 'steffon', members: n.size }.to_json)"
  )

  # 6. Per-app: keep the persistent `release` branch ahead of main (merge-forward
  #    guard), then deploy origin/release to that app's QA. The branch is
  #    populated by PR merges, so there's NO branch-cut/member-merge here. Gems
  #    are NOT deployed — they ride the release as a record, already published
  #    at 4c above (ship re-verifies idempotently).
  deployed = [] # [{repo, qa_app, qa_url, sha, ok}]
  qa_shas = {}  # { repo => sha } deployed to QA
  qa_smoke_started = false
  record_release_event(rel_slug, "deploy_qa", "started") if app_groups.any?
  repos.each do |group|
    repo    = group["repo"]
    members = group["members"] || []

    if group["kind"] == "gem"
      members.each do |m|
        step("gem member #{m['slug']} (#{repo} #{gem_version_local(repo)}) — rides the release; published BEFORE this QA deploy (step 4c), QA'd via its consuming app's bumped lock")
      end
      # Freeze the gem's origin/release HEAD into qa_shas, exactly like apps do at
      # the bottom of this loop. Without an entry the gem gets NO frozen SHA, so
      # at ship time frozen_sha_for falls back to resolving origin/release HEAD —
      # which can DRIFT if a PR merges into the gem's release branch after prepare.
      # Recording it here ships the exact commit QA froze. (Gems aren't QA-
      # deployed, but their release branch is still the source ship publishes from;
      # the frozen_sha_for fallback stays as defense for un-prepared repos.)
      sha = ""
      path = repo_path(repo)
      if !DRY && Dir.exist?(path)
        sh("git", "-C", path, "fetch", "origin", "--quiet")
        out, ok = sh("git", "-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}", capture: true)
        sha = out.strip if ok
      end
      qa_shas[repo] = sha
      next
    end

    # --- app repo: all branch ops happen in THAT repo via `git -C path` ---
    path   = repo_path(repo)
    qa_app = group["qa_app"]

    # Eligibility: a repo can be a registered app (passes validate_members!) yet
    # have NO QA env (tax-studio, chain-ops). Warn + skip its QA deploy rather
    # than firing a `bin/qa-server deploy` that has no target — it still ships at
    # `ship` via its prod_deploy adapter; it just can't be QA-reviewed here.
    unless qa_registered?(qa_app)
      say("")
      say("  ⚠ #{repo}: no QA environment registered (qa_environments.yml) — skipping QA deploy")
      next
    end

    say("")
    step("repo #{repo} → #{RELEASE_BRANCH} · #{members.size} member(s) · QA #{qa_app}")
    abort!("app repo not found at #{path} — clone it as a sibling at the projects root") unless DRY || Dir.exist?(path)

    # a. fetch the repo's origin.
    sh("git", "-C", path, "fetch", "origin", "--quiet")

    # b. merge-forward guard: `release` must always have main as an ancestor. If
    #    main has moved ahead (e.g. a hotfix landed on main), merge it forward so
    #    release never lags — abort with guidance on conflict.
    if DRY
      step("merge-forward guard: if origin/main isn't an ancestor of origin/release, merge origin/main → release in #{repo}")
    else
      _, in_sync = sh("git", "-C", path, "merge-base", "--is-ancestor", "origin/main", "origin/release", capture: true)
      unless in_sync
        step("merge-forward: origin/main → #{RELEASE_BRANCH} in #{repo} (main moved ahead)")
        sh("git", "-C", path, "checkout", RELEASE_BRANCH)
        _, fwd = sh("git", "-C", path, "merge", "origin/main", capture: true)
        unless fwd
          abort!("merge-forward conflict in #{repo}: origin/main → #{RELEASE_BRANCH}. Resolve by hand in #{path} " \
                 "(or `git -C #{path} merge --abort` to back out), commit, push, then re-run `bin/release prepare`.")
        end
        sh("git", "-C", path, "push", "origin", RELEASE_BRANCH)
      end
    end

    # c. deploy origin/release to the repo's own QA app. The github_actions apps
    #    (the hub — DevOps v2 Phase 2) dispatch ONE qa-deploy.yml run at the swept
    #    release tip: qa-deploy.yml is workflow_dispatch, not push:[release], so the
    #    N PR-merge pushes of the sweep never fire N QA deploys — the conductor
    #    fires exactly one. Every other app keeps the local qa-server force-push
    #    (qa-server resolves origin/release in the sibling and pushes its SHA — no
    #    local checkout/branch-cut). The /up boot poll (c2) gates the flip EITHER way.
    if (group["prod_deploy"] || {})["strategy"].to_s == "github_actions"
      tip = ""
      unless DRY
        out, tip_ok = sh("git", "-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}", capture: true)
        tip = out.strip if tip_ok
        abort!("could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the QA deploy dispatch") if tip.empty?
      end
      step("qa deploy: gh workflow run qa-deploy.yml -f sha=#{short(tip)} — GitHub Actions QA deploy of the release tip")
      qa_ok = dispatch_and_watch("qa-deploy.yml", { "sha" => tip }, chdir: path)
    else
      step("qa deploy: bin/qa-server deploy #{qa_app} origin/#{RELEASE_BRANCH} --yes")
      _, qa_ok = sh("bin/qa-server", "deploy", qa_app, "origin/#{RELEASE_BRANCH}", "--yes", capture: false)
    end

    # c2. wait for the dyno to actually BOOT before treating the deploy as done.
    #     `bin/qa-server deploy` returns once the push is accepted, but a slow dyno
    #     may still be booting — recording QA + assembling against it is the
    #     /up-smoke race that left the RC stuck `assembling`. Poll <qa_url>/up
    #     until 200 (or timeout); a non-200 marks the app NOT ok so step 4 leaves
    #     the release `assembling` for a clean re-run.
    if qa_ok && !qa_smoke_started
      record_release_event(rel_slug, "qa_smoke", "started")
      qa_smoke_started = true
    end
    # Route the /up boot poll through the telemetry wrapper (one scope, many
    # curls → block returns [out, ok]). `.last` keeps qa_ok a BOOLEAN (the raw
    # [out, ok] array is always truthy and would poison the ok flag downstream);
    # `&&=` still short-circuits, so a failed earlier step never runs the poll.
    qa_ok &&= run_test_scope("qa_up_smoke", repo: qa_app) do
      booted = wait_for_boot(qa_url_for(qa_app))
      [booted ? "200" : "", booted]
    end.last

    # d. capture the deployed SHA (origin/release after any merge-forward).
    sha = ""
    unless DRY
      out, ok = sh("git", "-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}", capture: true)
      sha = out.strip if ok
    end
    qa_shas[repo] = sha
    deployed << { "repo" => repo, "qa_app" => qa_app, "qa_url" => qa_url_for(qa_app),
                  "sha" => sha, "ok" => (qa_ok || DRY) }
  end

  # 7. Record the QA URL + per-repo deployed SHAs on the release (the board's
  #    current-release header links straight to QA; the SHAs give provenance).
  #    WRITES → suppressed in dry-run; recorded BEFORE the QA-green flip (step 8)
  #    but AFTER wait_for_boot, so the board links a booted QA dyno. This records
  #    the URL ONLY — the stage-advancing `deploy_qa:completed` stamp ("Live on
  #    QA" green) is deferred to qa_green! (step 8b) so it lands atomic with the
  #    member flip, never a step early.
  primary = deployed.find { |d| d["repo"] == APP } || deployed.first
  if primary && !primary["qa_url"].empty?
    step("record: qa_url #{primary['qa_url']}")
    conductor("Release::Conductor.record_qa_url(release: Release.current, qa_url: #{primary['qa_url'].inspect}); puts({qa_url: #{primary['qa_url'].inspect}}.to_json)")
  end
  unless qa_shas.empty?
    step("record: qa_shas #{qa_shas.map { |r, s| "#{r}@#{s.to_s[0, 7]}" }.join(', ')}")
    conductor("Release::Conductor.record_qa_shas(release: Release.current, shas: #{qa_shas.inspect}); puts({qa_shas: true}.to_json)")
  end

  # 8. QA-GREEN FLIP — the flip lands only AFTER every QA app booted
  #    (wait_for_boot returned 200) AND every post-deploy hook ran green:
  #    Release::Conductor.qa_green! flips the swept members `reviewed →
  #    assembled` (merged stays "release") and the RC assembling→assembled. A QA
  #    failure flips NOTHING — members stay `reviewed` (+ merged "release"), the
  #    RC stays `assembling`, and the next self-healing run picks them back up
  #    (skipping the already-done merges). WRITE → suppressed in dry-run.
  boot_failures = deployed.reject { |d| d["ok"] }
  qa_green = boot_failures.empty?
  # Close the qa_smoke release event opened above (it recorded `started` but never
  # a terminal status — the started-without-completed gap). `qa_smoke` IS a
  # whitelisted ReleaseEvent::STEP, so this closes the existing pair, not a new
  # step. Fired ONCE (matching the single `started`), guarded on qa_smoke_started.
  # `failed` lands here on a boot failure; `completed` is DEFERRED into the else
  # branch — it must land only after QA is ACTUALLY green through the BLOCKING
  # post-deploy hook, never a premature green (same reason 8b defers
  # deploy_qa:completed to the flip — "never a step early"). Best-effort.
  if boot_failures.any?
    record_release_event(rel_slug, "qa_smoke", "failed",
                         message: "#{boot_failures.size} app(s) never returned /up 200") if qa_smoke_started
    # G3 verdict: the candidate FAILED this attempt (a QA app never booted).
    # Attempt-aware — the re-run opens attempt n+1, so repeated QA failures
    # become visible signal instead of collapsing into one silent window.
    record_gate_close(rel_slug, "g3_candidate", false,
                      metadata: { "reason" => "#{boot_failures.size} app(s) never returned /up 200" })
    g3_gate = :closed
    say("")
    say("  ⚠ #{boot_failures.size} app(s) never returned /up 200 — QA is NOT green: leaving the release `assembling`,")
    say("    swept members stay `reviewed` (merged: release). Re-run `bin/release prepare` once they boot")
    say("    (the sweep skips the already-merged PRs): #{boot_failures.map { |d| d['repo'] }.join(', ')}")
  else
    # 8a. Post-deploy hooks on the booted QA app(s): run each member's declared
    #     post_deploy_cmd against its QA app, record the [post-deploy] outcome, and
    #     ABORT prepare on a non-zero exit (so the RC stays `assembling`, members
    #     stay `reviewed`, re-run resumes). dry-run prints the plan; nothing executes.
    run_post_deploy(repos, target: :qa)

    # QA is ACTUALLY green now — every app booted (/up 200) AND the blocking
    # post-deploy hook passed (run_post_deploy abort!s on failure, so REACHING
    # this line means it's green). Only NOW close qa_smoke `completed`; a
    # post-deploy abort must never leave a premature `completed` behind.
    record_release_event(rel_slug, "qa_smoke", "completed",
                         message: "all QA apps booted (/up 200) + post-deploy hooks green") if qa_smoke_started

    # 8b. QA is green — flip the swept members + the RC, and stamp Live-on-QA
    #     (deploy_qa:completed) in the SAME conductor call so the /deployments
    #     tracker reaches "Live on QA" atomic with the flip (never a step early).
    #     The reviewed→assembled usage (captured locally; the flip runs on prod,
    #     transcript-less) rides each member's assembled TaskEvent.
    unless DRY
      flip_slugs = cands.select { |c| c["stage"] == "reviewed" }.map { |c| c["slug"] }
      usage = move_usage_map(flip_slugs)
      live_qa_url = primary && !primary["qa_url"].to_s.empty? ? primary["qa_url"] : nil
      step("record: Release::Conductor.qa_green!(Release.current) — QA green, flip swept members `assembled` + stamp Live-on-QA")
      conductor(
        "r = Release.current; " \
        "Release::Conductor.qa_green!(r, usage_by_slug: #{usage.inspect}, qa_url: #{live_qa_url.inspect}) if r; " \
        "puts({ state: r&.reload&.state }.to_json)"
      )
    end

    # G3 verdict: the candidate PASSED — every app booted (/up 200), the
    # blocking post-deploy hooks ran green, and the QA-green flip landed.
    # Close the attempt with the collected SOPs (pre_qa_gate / qa_up_smoke /
    # qa_post_deploy). Best-effort, like every gate write.
    record_gate_close(rel_slug, "g3_candidate", true)
    g3_gate = :closed
  end

  # 9. Per-repo summary of what was swept + QA'd.
  say("")
  say("✓ #{qa_green ? 'Assembled' : 'Prepared (NOT assembled — QA not green)'} #{rel_slug}#{DRY ? ' (DRY RUN — nothing executed)' : ''}.")
  gem_groups.each do |g|
    g["members"].each { |m| say("  gem #{g['repo']} (#{m['slug']}) — rides the release; published before QA (ship re-verifies idempotently).") }
  end
  deployed.each do |d|
    loc = d["qa_url"].empty? ? d["qa_app"] : d["qa_url"]
    at  = d["sha"].to_s.empty? ? "" : " @ #{d['sha'][0, 7]}"
    if d["ok"]
      say("  app #{d['repo']} → #{RELEASE_BRANCH} → QA #{loc}#{at}")
    else
      say("  app #{d['repo']} → #{RELEASE_BRANCH} — QA deploy FAILED, retry `bin/qa-server deploy #{d['qa_app']} origin/#{RELEASE_BRANCH}`")
    end
  end
  say("  #{left_reviewed.join(', ')} left `reviewed` — no code on `#{ACCEPTED_BRANCH}` (re-review to heal), or `bin/task block` them.") if left_reviewed.any?
  # The Avi handoff exists only on QA-green — a NOT-green prepare hands off to
  # NOBODY (the step-8 warning already said: re-run prepare once QA boots).
  if qa_green
    say("")
    say("  Review the QA app(s) above, then hand off to Avi: `bin/release ship`.")
  end
  close_role_span(qa_green ? "assembled #{rel_slug} → QA" : "prepared #{rel_slug} — QA not green, members stay reviewed")
rescue SystemExit
  # G3 close-fail wrapper: an abort INSIDE the gate window (a red pre_qa_gate,
  # a QA-deploy/checkout abort, a post-deploy hook failure) IS the gate failing —
  # close the attempt `failed` with whatever SOPs were collected. record_gate_close
  # is itself best-effort (it can never raise), and the `raise` below ALWAYS
  # re-raises: the gate write must never mask the abort.
  record_gate_close(rel_slug, "g3_candidate", false, metadata: { "aborted" => true }) if g3_gate == :open
  # An abort mid-prepare closes the Steffon activity with the abort outcome
  # (best-effort) before re-raising, so the heartbeat activity resolves instead of
  # hanging open.
  close_role_span("prepare aborted before QA-green") if steffon_span
  raise
end

# --- eject (block-on-regression) ---------------------------------------------
# Pull ONE offending task off the release candidate — the pre-QA gate (or QA
# itself) caught a regression it owns. The record side
# (Release::Conductor.eject!) detaches it (release_slug + merged cleared) and
# blocks it for rework with the feedback as a qa_feedback note; the REST of the
# RC rides on untouched. The git side stays with the operator (printed guidance):
# revert the member's merge commit on `release` — never a force-push — then
# re-run `bin/release prepare`.
def eject
  feedback = opt_value("--feedback")
  slug = Release::Cli.positional_slugs(ARGV).first
  abort!("usage: bin/release eject <task-slug> [--feedback \"…\"]") unless slug

  say("Eject #{slug} from the release train#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # Free-text feedback is safe to embed via .inspect: the whole snippet rides
  # `heroku run` as a url-safe Base64 blob (conductor_payload), so quotes/parens
  # survive the remote re-quoting intact.
  feedback_ruby = feedback.to_s.empty? ? "nil" : feedback.inspect
  step("record: Release::Conductor.eject!(#{slug}) — detach + block for rework")
  result = conductor(
    "t = Task.find_by!(slug: #{slug.inspect}); " \
    "Release::Conductor.eject!(t, feedback: #{feedback_ruby}); " \
    "puts({ slug: t.slug, stage: t.reload.stage, merged: t.merged }.to_json)"
  )
  say("  #{slug} → blocked (rework)#{feedback ? ' — feedback noted' : ''}") unless DRY || result.empty?

  say("")
  say("Now unwind its code from the branch (the record is detached; git is yours):")
  say("  1. find its merge commit:  git log origin/#{RELEASE_BRANCH} --oneline --merges | head")
  say("  2. revert it (never force-push): git revert -m 1 <merge-sha> && git push origin #{RELEASE_BRANCH}")
  say("  3. re-run `bin/release prepare` — the sweep self-heals and the REST of the RC rides on.")
end

# --- ship (multi-repo, producer-first) -------------------------------------
# "Run Deployment": promote the assembled RC to production across EVERY member
# repo in a producer-first, hub-before-satellites loop —
#   gems (publish to RubyGems) → auto-re-pin consumers → hub app → satellites.
# It ships the QA-FROZEN SHA per repo (the commit QA deployed, from
# release.metadata["qa_shas"]) — NOT origin/release HEAD — so a PR merged after
# `prepare` can never ride out un-QA'd. ONE confirm authorizes the whole train
# (turf included; its own bin/deploy keeps smoke + rollback), so there is no
# per-satellite re-prompt. Partial-ship: abort on the first failure; ship!/notes
# run LAST so a partial leaves the record `assembled` (recoverable) and a re-run
# is idempotent (published gems skip, ff no-ops, re-pins are idempotent).
#
# bin/release does only git/gh/gem/bundle I/O here; the string/version/ordering
# DECISIONS live in the unit-tested Release::ShipSequence (+ GemfileRepin).

# --- the clean-release GUARD (`deploy-with-task` runs this FIRST) -----------
# `bin/release status` reports whether `release == main` — i.e. whether the only
# thing a `release → main` fast-forward would ship is ONE freshly-merged task, or
# whether OTHER assembled-but-unshipped work is already riding `release`. Avi's
# `deploy-with-task` act runs `bin/release status --clean-only`
# BEFORE it merges the expedited task; `--clean-only` turns the report into a
# GATE — it exits nonzero (aborting the expedite) on a dirty release, after
# printing the refusal + the `full-cycle` offer. The pure verdict +
# message live in Release::CleanCheck; this owns only the two live reads.
def status
  clean_only = Release::Cli.take_flag(ARGV, "--clean-only")

  say("Release status#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Board signal (read-only, runs even in --dry-run): every task whose code is
  #    already ON `release` but not yet shipped — `assembled` (QA-green, waiting
  #    on Avi) PLUS `reviewed` with merged:"release" (swept, QA in flight) — and
  #    the current release for context. A read mutates nothing, so it's safe
  #    under --dry-run.
  step("read (read-only): tasks riding `release` pending ship + Release.current")
  board = conductor(
    "pending = Task.where(stage: 'assembled').or(Task.where(stage: 'reviewed', merged: 'release'))" \
    ".order(:position).map { |t| { slug: t.slug, title: t.title } }; " \
    "r = Release.current; " \
    "puts({ pending: pending, release: (r ? { slug: r.slug, state: r.state } : nil) }.to_json)",
    read_only: true
  )
  pending = board["pending"] || []
  rel = board["release"]
  say("  current release: #{rel ? "#{rel['slug']} (#{rel['state']})" : 'none active'}") if rel || !DRY

  # 2. Git signal: per release repo, how far origin/release is AHEAD of
  #    origin/main. Skipped under --dry-run (fetches touch the network); the
  #    board signal alone drives the previewed verdict then.
  repo_states = release_ahead_states

  verdict = Release::CleanCheck.evaluate(pending_tasks: pending, repo_states: repo_states)
  say("")
  say(verdict["message"])

  # --clean-only is the GATE: a dirty release aborts the expedite (non-zero exit)
  # so `deploy-with-task` refuses instead of dragging the pending work to prod.
  # A --dry-run previews the verdict without aborting (nothing is executed).
  if clean_only && !verdict["clean"] && !DRY
    abort!("release is not clean — `deploy-with-task` refused (ship the whole release with the `full-cycle` launcher)")
  end
end

# The git signal for the clean check: per release repo, the number of commits
# origin/release is AHEAD of origin/main (0 ⇒ that repo's release == main). This
# is the I/O seam (fetch + rev-list) `status` calls, split out so the tests stub
# it the way they stub `conductor`. Returns [] under --dry-run (a preview runs no
# git — the board read alone drives the previewed verdict) and skips any repo not
# cloned as a sibling.
def release_ahead_states
  return [] if DRY

  release_repo_slugs.filter_map do |repo|
    path = repo_path(repo)
    next unless Dir.exist?(path)

    sh("git", "-C", path, "fetch", "origin", "--quiet")
    out, ok = sh("git", "-C", path, "rev-list", "--count", "origin/main..origin/#{RELEASE_BRANCH}", capture: true)
    next unless ok

    { "repo" => repo, "ahead" => out.strip.to_i }
  end
end

SHORT = 7
def short(sha) = sha.to_s.empty? ? "(frozen)" : sha.to_s[0, SHORT]

# A git read that runs EVEN in dry-run (a read mutates nothing) — mirrors how
# `conductor(read_only:)` lets a dry-run preview real state. Returns [out, ok?].
def git_capture(*args)
  out, status = Open3.capture2e("git", *args)
  [out, status.success?]
end

def gem_meta_for(repo) = RELEASE_REPOS.dig("gems", repo) || {}
def app_meta_for(repo) = RELEASE_REPOS.dig("apps", repo) || {}

# A gem's declared version AT a git ref — `git show <ref>:<version_file>`, parsed
# the same way as the local read. This is the read that fixes the publish-skip:
# ship BUILDS + PUBLISHES the gem from the QA-frozen commit, so the version that
# decides "already live? skip : publish" MUST come from THERE — not the pre-ff
# local checkout, which still sits on stale `main` and reports the PREVIOUS version
# (the 0.10.0/0.11.0 skip that shipped a release without ever publishing the bumped
# gem). A pure read (git_capture) so it runs even in --dry-run, letting the dry-run
# plan + label show the version that will actually publish. Returns "" when the ref
# or version_file is blank, the repo isn't checked out, or git can't read the blob.
def gem_version_from_ref(repo, ref)
  version_file = gem_meta_for(repo)["version_file"].to_s
  return "" if version_file.empty? || ref.to_s.empty?

  out, ok = git_capture("-C", repo_path(repo), "show", "#{ref}:#{version_file}")
  return "" unless ok

  out[/version\s*=\s*["']([\w.\-]+)["']/i, 1].to_s
end

# A gem's publish version, resolved from the version that will ACTUALLY build at
# ship — read at the QA-frozen SHA (`frozen_ref`), NOT the pre-ff local checkout.
# Reading the frozen ref is the fix for the publish-skip bug; member_plan's recorded
# version and the local checkout stay as fallbacks for when there's no ref to read
# (a release prepared before SHA recording, or an un-frozen preview).
def gem_version_for(repo, group, frozen_ref = nil)
  from_ref = gem_version_from_ref(repo, frozen_ref)
  return from_ref unless from_ref.empty?

  member = (group["members"] || []).find { |m| !m["version"].to_s.empty? }
  return member["version"].to_s if member

  gem_version_local(repo)
end

# The QA-frozen SHA to ship for a repo — the value `prepare` recorded under
# release.metadata["qa_shas"] (apps AND gems both freeze it now). The PURE
# present?/which-SHA decision lives in Release::ShipSequence.frozen_sha so this
# stays thin; only the live-git fallback (resolve origin/release HEAD when a repo
# was never frozen — e.g. a release prepared before SHA recording) is I/O and
# stays here. Resolved live only (DRY returns "").
def frozen_sha_for(repo, qa_shas)
  frozen = Release::ShipSequence.frozen_sha(qa_shas, repo)
  return frozen if frozen
  return "" if DRY

  out, ok = git_capture("-C", repo_path(repo), "rev-parse", "origin/#{RELEASE_BRANCH}")
  ok ? out.strip : ""
end

# The RubyGems versions listing for the idempotency check: the parsed
# /api/v1/versions/<gem>.json — an array of { "number" => ... } entries, all LIVE
# (RubyGems excludes yanked versions from the listing entirely; there is no
# `yanked` field). 404 (never published) or any error → [] (publish needed). A
# live-only read.
def rubygems_versions(gem_name)
  out, status = Open3.capture2e("/usr/bin/curl", "-sf",
                                "https://rubygems.org/api/v1/versions/#{gem_name}.json")
  return [] unless status.success? && !out.strip.empty?

  JSON.parse(out)
rescue JSON::ParserError
  []
end

# Detached checkout of a repo at a SHA so the gem artifact builds from the
# QA-frozen commit. Aborts on a failed checkout (never build from the wrong tree).
def checkout_detached(repo, sha)
  path = repo_path(repo)
  abort!("gem repo not found at #{path} — clone it as a sibling at the projects root") unless Dir.exist?(path)
  sh("git", "-C", path, "fetch", "origin", "--quiet")
  _, ok = sh("git", "-C", path, "checkout", sha, capture: true)
  abort!("could not checkout #{short(sha)} in #{repo} to build the gem — fetch it or re-run prepare") unless ok
end

# Advance a repo's `main` to the QA-FROZEN SHA — the release → main collapse that
# `main` deploys from. A pure REF PUSH:
#
#   git -C <repo> push origin <frozen>:refs/heads/main
#
# WHAT THIS REPLACED, and why (2026-07-12). It used to be `ff_main_local` +
# `push_origin_main`: check out `main` in the SHARED PRIMARY, `pull`, `merge
# --ff-only <frozen>`, then push the local branch. That made the deploy depend on
# the primary's WORKING TREE — so ship's preflight had to refuse a dirty primary,
# and a concurrent feature session's staged work ABORTED a production ship after
# the gems had published. But advancing a remote branch never needed a working
# tree at all: a ref push reads the shared OBJECT STORE and nothing else. It does
# not move HEAD, does not touch the index, and runs happily while a feature agent
# has half a feature staged one directory over.
#
# It keeps every safety property of the old ff:
#   * FAILS CLOSED on divergence — git rejects a non-fast-forward ref update
#     without --force (verified), exactly as `merge --ff-only` did. We NEVER pass
#     --force here; a rejected push must abort the ship, not rewrite prod's history.
#   * SHIPS THE FROZEN SHA — the pushed ref is the SHA itself, not "whatever the
#     local main happened to be after an ff", so there is no window in which a
#     stale/raced local branch could be pushed instead.
#   * IDEMPOTENT — a re-run of a completed ship pushes an already-current ref
#     ("Everything up-to-date"), the same no-op the ff was.
# The local `main` in the primary is deliberately left alone; `restore_primaries`
# fast-forwards it afterwards, best-effort, and nothing in the ship reads it.
def push_frozen_main(repo, sha)
  sha = sha.to_s.strip
  step("push #{repo} origin main → frozen #{short(sha)} (ref push — no checkout, no working tree)")
  return if DRY

  abort!("no frozen SHA to push for #{repo} — re-run `bin/release prepare`") if sha.empty?

  path = repo_path(repo)
  abort!("repo not found at #{path} — clone it as a sibling at the projects root") unless Dir.exist?(path)

  _, ok = sh("git", "-C", path, "push", "origin", "#{sha}:refs/heads/main")
  unless ok
    abort!("could not fast-forward #{repo} origin/main to #{short(sha)} — git REFUSED the ref update, which " \
           "means origin/main has diverged from the frozen SHA (someone pushed to main). NOT forcing. " \
           "Reconcile main, re-run `bin/release prepare` to re-freeze, then re-run `bin/release ship`.")
  end

  # main is advanced — now re-baseline this repo's origin/accepted onto it
  # (guarded, idempotent, NON-FATAL). See advance_accepted.
  advance_accepted(repo, path, sha)
end

# After push_frozen_main advances a repo's `main`, re-baseline that repo's
# persistent `accepted` integration branch onto the same frozen SHA. This retires
# the manual post-ship chore the conductor has run by hand after every ship —
# `git push origin origin/main:refs/heads/accepted` — because `accepted` (feature
# branches are cut from and PR into it) is left STALE behind `main` after a ship
# and nothing else re-baselines it. DevOps v2 Phase 3, Slice 1: a step toward
# Phase 3 fully automating accepted-maintenance; a later slice restructures the
# ladder and retires the manual chore entirely.
#
# Three properties, each load-bearing:
#
#   * GUARDED — advance ONLY a repo that HAS an origin/accepted, queried LIVE
#     against the remote with `ls-remote` (not the primary's remote-tracking ref,
#     which can be stale or missing here and would false-negative the guard into
#     never advancing). A repo without an accepted branch (rolio/turf, pre-Phase-5)
#     is a clean NO-OP. The yes/no is the pure ShipSequence.advance_accepted?.
#
#   * FAIL-CLOSED — no --force. `accepted` trails `main`, so the advance is
#     normally a fast-forward; a non-ff means `accepted` has DIVERGED (someone
#     pushed to it), and forcing would silently discard that. git refuses the
#     non-ff and we leave it for a human.
#
#   * NON-FATAL — `main` is already advanced and the deploy is landing, so a failed
#     accepted push (a divergence, a transient git error) must NEVER abort a live
#     ship. Warn with the manual command and CONTINUE — the same best-effort
#     contract as the merged:main stamp (record_merged_main).
def advance_accepted(repo, path, sha)
  _, exists = sh("git", "-C", path, "ls-remote", "--exit-code", "--heads", "origin", "accepted", capture: true)
  return unless Release::ShipSequence.advance_accepted?(sha: sha, accepted_exists: exists)

  step("advance #{repo} origin/accepted → #{short(sha)} (ref push — accepted trails main)")
  _, ok = sh("git", "-C", path, "push", "origin", "#{sha}:refs/heads/accepted")
  return if ok

  say("  ⚠ #{repo}: origin/accepted NOT advanced to #{short(sha)} — git refused the ref update " \
      "(accepted has DIVERGED from main; NOT forcing). Deploy continues — reconcile by hand: " \
      "git -C #{path} push origin #{sha}:refs/heads/accepted")
rescue SystemExit, StandardError => e
  say("  ⚠ #{repo}: origin/accepted advance failed (#{e.message}); deploy continues (maintenance only)")
end

# Put a GEM repo's primary checkout back on `main` after the artifact build left it
# DETACHED at the frozen SHA (checkout_detached). Gems are the one place the ship
# still builds from the primary — `gem build` packages what is on disk — so it is
# the one place that has to tidy up after itself.
#
# BEST-EFFORT (warn, never abort): by the time this runs the gem is PUBLISHED and
# origin/main is pushed. A checkout that can't be restored is a cosmetic
# inconvenience in the operator's sibling; aborting the train over it would strand
# a half-shipped release for no safety gain.
def restore_gem_primary(repo)
  return if DRY

  path = repo_path(repo)
  _, co = sh("git", "-C", path, "checkout", "main", capture: true)
  unless co
    say("  ⚠ #{repo}: left on a detached HEAD (couldn't check out main) — `git -C #{path} checkout main` when free")
    return
  end
  _, ff = sh("git", "-C", path, "merge", "--ff-only", "origin/main", capture: true)
  say("  ⚠ #{repo}: main not fast-forwarded to origin/main — `git -C #{path} pull` when free") unless ff
end

# The SHIP WORKSPACE: the private, detached checkout the deploy works in, pinned at
# the QA-frozen SHA. Same primitive as the gate's (Release::GateWorkspace), a
# different role — so it is a different directory (.worktrees/_ship), a different
# test DB (<app>_ship_test) and a different lock, and a prod deploy can never queue
# behind, or reset the tree under, a concurrent conductor's G3 gate suite.
#
# Only two things in the ship genuinely need a working tree, and both use this one:
#   * the auto-re-pin commit (repin_consumers — `bundle lock` writes Gemfile.lock),
#   * a `repo_script` app's deploy (deploy_app — turf's bin/deploy runs its own
#     suite, reads config/*.idl.json, and pushes from the checkout it runs in).
# Everything else the ship does to git is a ref push (push_frozen_main), which
# needs no tree at all.
def ship_workspace!(repo, sha)
  gate_workspace!(repo, sha, role: "ship")
end

# Bring a ship workspace to a runnable state for a repo whose own deploy script
# runs a SUITE there (the repo_script satellites — turf's bin/deploy runs `bin/rails
# test` before it pushes). Same preparation as a gate's: the bundle under the suite
# ruby, and a test DB PROVEN private to this workspace before `db:test:prepare`
# purges it. Without it, turf's pre-prod suite would run against the SHARED
# `turf_monster_test` — the cross-talk that false-fails green code, here at the
# worst possible moment (mid-ship, after the gems published).
#
# These are the CONDUCTOR'S OWN commands (bundle check, the DB probe,
# db:test:prepare), so they correctly run under the full gate overlay — RAILS_ENV
# =test and all. The DEPLOY SCRIPT does not (see ship_deploy_env).
def prepare_ship_workspace!(repo, path)
  prepare_gate_workspace!(repo, path, role: "ship")
end

# The env for a repo's OWN deploy script — deliberately NOT the gate overlay.
#
# It hands over exactly ONE var: DATABASE_URL, pointing at the workspace's private
# test DB, so the suite the script runs pre-prod (turf's `bin/rails test`) can't be
# poisoned by — or poison — a concurrent suite on the shared `turf_monster_test`.
# VERIFIED before shipping this: turf's FULL suite (1404 runs) is green in a fresh
# detached workspace under exactly this invocation, with no built assets and no
# node_modules.
#
# It must NOT be gate_env(), even though that would be the obvious reuse.
# Release::GateEnv sets RAILS_ENV=test (right for a gate, which runs nothing but
# test commands) — and this is a PRODUCTION DEPLOY SCRIPT. Handing it RAILS_ENV
# =test changes a contract it never agreed to: turf's bin/deploy happens to run
# only `bin/rails test`, but the next repo_script app (tax-studio, chain-ops) could
# precompile assets or run a rails task in its deploy, and doing that under
# RAILS_ENV=test would build the WRONG artifact and ship it. The ruby pin is out
# for the same reason: the script's toolchain is the script's business. The change
# this task makes to a satellite deploy is its CWD — a clean, pinned tree instead
# of a shared primary — and nothing else.
#
# KNOWN CONSTRAINT, for whoever registers the NEXT repo_script app: DATABASE_URL is
# a Rails BUILTIN and is not test-scoped — Rails merges it into the resolved config
# of WHATEVER env is current. It lands on the test DB here only because the one
# rails command turf's bin/deploy runs is `bin/rails test`. A deploy script that
# also ran a DEVELOPMENT-env rails command would silently connect it to
# <app>_ship_test. Harmless today (it is a scratch test DB, and nothing in a deploy
# script has business reading a local dev DB), but a repo_script deploy must not
# assume its dev database. Registry contract: config/release_repos.yml.
#
# {} for an app whose test DB is file-backed inside the workspace (SQLite) — it is
# private already, and `sh` drops an empty overlay.
def ship_deploy_env(repo)
  url = gate_database_url(repo, role: "ship")
  url.to_s.empty? ? {} : { "DATABASE_URL" => url }
end

# Stamp `merged: "main"` on a repo's member tasks right after that repo's
# `release → main` fast-forward lands on origin — the git-location signal
# (matrix: assembled+main = ff'd, prod-deploy in flight) an interrupted Avi run
# reads to skip re-ff'ing. BEST-EFFORT (warn + continue): the ffs are git no-ops
# on a re-run and Task#ship! re-stamps "main" at the record step, so a board blip
# here must never abort a mid-train prod deploy. A board WRITE → suppressed in
# --dry-run (conductor prints the plan).
def record_merged_main(slugs)
  slugs = Array(slugs).compact
  return if DRY || slugs.empty?

  step("record: merged:main for #{slugs.join(', ')} (release → main ff landed)")
  conductor(
    "Release::Conductor.record_merged!(slugs: #{slugs.inspect}, merged: 'main'); " \
    "puts({ merged_main: #{slugs.inspect} }.to_json)"
  )
rescue SystemExit, StandardError => e
  say("  ⚠ merged:main not recorded for #{slugs.join(', ')} (#{e.message}); deploy continues — ship! re-stamps it")
end

# The conductor's pre-prod test gate: run the registry `test_cmd` at the repo's
# frozen SHA before the irreversible deploy; scoped-abort on red. repo_script
# apps SELF-GATE (their own deploy runs tests) → no test_cmd → skipped.
#
# G4 SELF-GATING (the 90/10 policy): the full suite runs ONCE per release batch,
# at G3 — so this gate may skip, but ONLY on PROOF that G3 actually ran and
# passed. That proof is G3's OWN RECORDED VERDICT,
# release.metadata["qa_gates"][repo] = {sha, cmd, ok}, which pre_qa_gate writes
# only after a green suite. Same command + same frozen SHA + green => skip.
#
# It deliberately does NOT infer the proof from the registry + release.metadata
# ["qa_shas"] (the old rule): qa_shas is stamped by the QA DEPLOY LOOP, so it
# records what was DEPLOYED, never what was CERTIFIED — which let a SKIPPED G3
# still satisfy the skip and silently disarm this gate. No record, a red record,
# a different command, or a drifted/straggler SHA all FAIL OPEN and run the gate.
# The skip is recorded as a visible SOP on the g4_ship gate run, never a silent
# omission. (The pure decision lives in Release::ShipSequence.ship_gate_skip?,
# unit-tested.)
#
# A G3 whose AUDITOR went RED also fails open — G3 called the SHA green, GitHub CI
# called the SAME SHA broken, so the batch certification is exactly what must not
# be trusted. Without this the skip would fire (the frozen SHA *is* the certified
# SHA) and G3's alarm would be the ONLY thing between a CI-red commit and prod.
# FAIL-OPEN ONLY: a red auditor causes MORE checking, never a block, and no-data
# (none/pending/unverified) changes nothing.
# The G4 fail-closed abort text. A RED CI is a broken frozen commit — it must not
# ship. Any OTHER non-green (none/pending/unverified/unreadable) is CI without a
# green verdict for the frozen SHA yet (a just-pushed re-pin may still be pending):
# hold and re-run, or take the first-class --skip-test-gate override. Never a pass.
def ship_test_gate_ci_abort(repo, frozen_sha, ci)
  if ci[:state] == :red
    named = Array(ci[:failing]).join(", ")
    "test gate FAILED for #{repo}: GitHub CI called frozen #{short(frozen_sha)} " \
      "RED#{named.empty? ? '' : " (#{named})"} — aborting BEFORE the irreversible prod deploy. A red frozen SHA " \
      "must not ship: read the failing check, fix on `#{RELEASE_BRANCH}` + re-run `bin/release ship`."
  else
    "test gate HELD for #{repo}: GitHub CI has NO green verdict for frozen #{short(frozen_sha)} (#{ci_detail(ci)}). " \
      "The ship gate is CI now and FAILS CLOSED on anything but green — a just-pushed re-pin may still be PENDING, " \
      "and an :unreadable state is a token fault. Wait for CI to conclude on the frozen SHA, then re-run " \
      "`bin/release ship`. To ship past a verdict you believe is a false negative, use " \
      "`bin/release ship --skip-test-gate --reason \"…\"` (records a RED gate)."
  end
end

def test_gate(repo, frozen_sha: nil, qa_gate: nil)
  cmd = app_meta_for(repo)["test_cmd"].to_s
  if cmd.empty?
    step("test gate: #{repo} self-gates (no conductor test_cmd; its deploy runs tests) — skip")
    return
  end

  # Say WHY the batch certification is being ignored — a gate that silently
  # re-derives teaches the operator nothing, and this is the one signal that says
  # "G3's record and CI disagreed about this exact commit".
  #
  # DevOps v2 Phase 3: a red-auditor G3 record is now DEFENSIVE — G3 derives ok from CI
  # (ci_pass?), so a red CI aborts prepare and never produces a green ok:true record.
  # A stale or hand-built record can still carry this shape, and it must still be
  # re-gated, never trusted. G4 re-derives the verdict from GitHub CI on the FROZEN SHA
  # below — which, unlike the demoted local suite, CAN see every lane — and fails the
  # ship CLOSED if that SHA is not green.
  #
  # Name the SHA G3's record CERTIFIED (record["sha"]), not the frozen ship SHA: when
  # the RC was re-pinned the two differ, and "G3 certified <frozen_sha>" would be a
  # second false claim printed by the very code that exists to kill one.
  if Release::ShipSequence.auditor_red?(qa_gate)
    audited_sha = (qa_gate["sha"] || qa_gate[:sha]).to_s
    say("  ⚠ #{repo}: G3's record certified #{short(audited_sha)} GREEN but GitHub CI called that SHA RED — the " \
        "batch certification is NOT trusted, so G4 does not self-skip on it. It RE-DERIVES the verdict from " \
        "GitHub CI on frozen #{short(frozen_sha)} below, and CI fails this gate closed if that SHA is not green.")
  end

  if Release::ShipSequence.ship_gate_skip?(test_cmd: cmd, frozen_sha: frozen_sha, qa_gate: qa_gate)
    step("test gate: #{repo} self-gates — `#{cmd}` already CERTIFIED green on frozen #{short(frozen_sha)} " \
         "by the G3 pre-QA gate this run; skip (a drifted SHA, a G3 that never ran, or a RED CI auditor " \
         "re-triggers)")
    gate_sop("ship_test_gate", "skipped — #{cmd} certified green @ #{short(frozen_sha)} at G3 (recorded pre-QA verdict)", true)
    return
  end

  # THE OPERATOR ESCAPE HATCH — explicit, confirmed, and LOUD.
  #
  # The old way to ship past a gate you believed was a false negative was to blank
  # the registry's test_cmd/qa_test_cmd. That is now closed (it SILENTLY DISARMED
  # this gate — see ship_gate_skip?), and closing it without a replacement would
  # WEDGE the operator: a G4 false negative with no clean override, and a config
  # edit is not one (it is un-reviewed drift in the registry the gate reads). So the
  # override is
  # first-class: it demands a reason, it asks before it skips, and it records a RED
  # gate SOP — a skipped gate is now visible in the release record forever, where
  # the old trick left one that read "already green".
  if SKIP_TEST_GATE
    reason = opt_value("--reason").to_s.strip
    abort!("--skip-test-gate requires --reason \"…\" (it is recorded on the release as a red gate)") if reason.empty?
    unless confirm("⚠ SKIP the #{repo} ship test gate (`#{cmd}`) on frozen #{short(frozen_sha)}? " \
                   "The suite will NOT run before the irreversible prod deploy. Reason: #{reason}")
      abort!("ship aborted — test gate not skipped")
    end
    step("⚠ test gate: SKIPPED BY OPERATOR for #{repo} (--skip-test-gate) — #{reason}")
    gate_sop("ship_test_gate",
             "⚠ SKIPPED BY OPERATOR (--skip-test-gate): #{reason} — `#{cmd}` did NOT run on #{short(frozen_sha)}",
             false)
    return
  end

  # Validate the registry command even though the suite is DEMOTED (Phase 3): a
  # malformed value must still abort a preview. test_cmd_argv aborts on an unbalanced quote.
  test_cmd_argv(cmd)
  step("test gate: #{repo} — GitHub CI verdict for frozen #{short(frozen_sha)} " \
       "(#{cmd} recorded, not run; before prod)")
  return if DRY

  # DevOps v2 Phase 3+4: the frozen SHA's last gate before prod is GitHub CI's
  # conclusion for that exact commit (ci_pass?), not a re-run of the local suite.

  # THE VERDICT, fail-CLOSED before the irreversible prod deploy: ci_pass? passes on
  # ONLY :green. A red (a broken frozen commit) and every no-data/pending state
  # (none/pending/unverified/unreadable — e.g. a just-pushed re-pin whose CI has not
  # concluded) all FAIL the gate. A false green is the one error that ships untested
  # code to production. CI's conclusion is recorded as this gate's Tier-3 SOP.
  ci = ci_verdict(repo, frozen_sha)
  ok = ci_pass?(ci)
  gate_sop("ship_test_gate",
           "GitHub CI #{ci[:state].to_s.upcase} @ #{short(frozen_sha)} — #{cmd} " \
           "(Tier-3 Actions conclusion; local suite demoted)", ok)
  abort!(ship_test_gate_ci_abort(repo, frozen_sha, ci)) unless ok
end

# `bundle lock --update <gem>` with a bounded retry/backoff for RubyGems
# propagation lag (a just-pushed version isn't always instantly resolvable).
# `conservative:` adds bundler's --conservative so a SINGLE-gem bump can't float
# the rest of the dependency graph — the prepare-side consumer bump passes it
# (the lock lands on `release` and ships; only the published gem may move).
def bundle_lock(path, gem, attempts: 3, conservative: false)
  args = ["bundle", "lock", "--update", gem]
  args << "--conservative" if conservative
  delay = 5
  attempts.times do |i|
    step("#{args.join(' ')} (cd #{path}) [#{i + 1}/#{attempts}]")
    _, ok = sh(*args, chdir: path)
    return if ok
    break if i == attempts - 1

    say("  bundle lock failed — RubyGems may not have propagated #{gem} yet; retrying in #{delay}s")
    sleep(delay)
    delay *= 2
  end
  abort!("#{args.join(' ')} failed in #{path} after #{attempts} tries — re-run once RubyGems has propagated")
end

# --- prepare-side gem publish (producer-first, BEFORE the pre-QA gate + QA) ----
#
# WHY AT PREPARE (publish-gems-before-qa): ship used to be the first publish, so
# QA never tested what prod would build — the consumer's QA deploy bundled its
# COMMITTED Gemfile.lock (the OLD gem), ship then published the new gem and
# repinned, and prod built a tree QA never saw. Worse, an unbumped version_file
# made the ship publish silently self-skip (publish_needed? false), STRANDING
# gem commits with every gate green. prepare now mirrors ship's producer-first
# sequence up front: publish each swept gem member's origin/release version,
# then commit each consumer's lock bump onto its release branch — BEFORE the
# pre-QA gate reads CI's verdict and BEFORE any QA deploy, so the gate's SHA,
# the QA tree, and the prod tree are the SAME tree.
#
# THE ACCEPTED COST: a publish is irreversible (RubyGems forbids re-pushing a
# number), so a QA bounce can orphan a published version — the next fix bumps
# PAST it and the dead number just sits on RubyGems, harmless. That trade is
# deliberate: an occasional dead version buys QA testing the real artifact.
#
# Ship's publish stays, now as the idempotent VERIFY: on the happy path every
# version is already live (skip), and it remains the backstop for a release
# prepared before this change. Everything here is idempotent for the
# self-healing re-run: already-live versions skip, an already-bumped lock
# commits nothing.
# PHASE 1 — VALIDATE EVERY GEM, PUBLISH NOTHING. A RubyGems push can never be
# re-pushed, so every check THIS PHASE OWNS runs for EVERY swept gem BEFORE the
# first push: repo cloned, buildable primary (the artifact builds from disk),
# FAIL-CLOSED fetch (a stale origin/release must never drive an irreversible
# decision), version_file parses, stranded-work guard (ORDERING — the version
# must be strictly newer than the last published tag; equal, backward, and
# unparseable all block), and a consuming app IN THIS SWEEP whose
# origin/release Gemfile declares the gem — without one the published gem would
# assemble QA-green with QA never bundling it (the gem-only bypass). ANY
# failure aborts with every finding named and ZERO gems published. Returns the
# validated publish plan phase 2 executes.
#
# WHAT PHASE 1 DOES **NOT** COVER (be precise — an overclaim here is exactly the
# kind of green badge on wrong behavior this PR exists to remove):
#   * The gem's own `release_check`/`gem build` runs inside publish_gem, in
#     PHASE 2 (see :1019-1028). So a gem whose BUILD is red is caught only when
#     its turn to publish arrives — with an earlier gem already pushed. Phase 1
#     shrinks the multi-gem blast radius to build failures alone; it does not
#     eliminate it. Closing that fully means building every gem artifact up
#     front (a real cost for the rare multi-gem sweep) — deliberately deferred,
#     and NOT claimed here.
#   * `already_live` is read from RubyGems in phase 1 and consumed in phase 2 —
#     a TOCTOU on a network read. Worst case is a redundant push that RubyGems
#     rejects and publish_gem aborts on, loudly. Fail-closed, so it is a wasted
#     run, never a wrong publish.
def validate_gems_for_qa(gem_groups, app_groups)
  return [] if gem_groups.empty?

  say("")
  step("gem publish (producer-first, BEFORE the pre-QA gate + any QA deploy): " \
       "preflight EVERY swept gem, then publish from origin/#{RELEASE_BRANCH}, then bump consumer locks")

  if DRY
    gem_groups.each do |group|
      step("  gem #{group['repo']}: preflight (fail-closed fetch → version parses → stranded-work guard " \
           "(commits past the last tag with an unbumped version_file ABORT) → a swept consumer declares " \
           "the gem) — ALL swept gems validate BEFORE the first irreversible push → then publish the " \
           "origin/#{RELEASE_BRANCH} version to RubyGems (skip if already live) → tag v<version>")
    end
    return gem_groups.map { |g| { "repo" => g["repo"], "version" => "", "dry" => true } }
  end

  failures = []
  if app_groups.empty?
    failures << "the sweep carries #{gem_groups.map { |g| g['repo'] }.join(', ')} but NO app member — " \
                "a gem-only candidate would publish with no consumer lock bump, no pre-QA gate, and no " \
                "QA deploy, then assemble QA-green untested; enroll the consuming app in the sweep " \
                "(or eject the gem member)"
  end
  consumers = validated_consumer_gemfiles(app_groups, failures)

  plan = []
  gem_groups.each do |group|
    repo = group["repo"]
    path = repo_path(repo)
    unless Dir.exist?(path)
      failures << "gem repo not found at #{path} — clone it as a sibling at the projects root"
      next
    end

    # The artifact is BUILT from the gem's primary checkout (`gem build` packages
    # what is ON DISK) — ship_preflight's one surviving primary hazard.
    dirt = Release::ShipSequence.gem_build_offenders([repo_git_state(repo, path)])
    if dirt.any?
      failures << Release::ShipSequence.gem_build_message(dirt, root: projects_root)
      next
    end

    _, fetched = sh("git", "-C", path, "fetch", "origin", "--tags", "--quiet")
    unless fetched
      failures << "git fetch failed in gem #{repo} — a stale origin/#{RELEASE_BRANCH} must never drive an " \
                  "irreversible publish (fail closed); fix the remote, then re-run `bin/release prepare`"
      next
    end

    out, ok = git_capture("-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}")
    unless ok
      failures << "could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the gem publish — " \
                  "fetch, then re-run `bin/release prepare`"
      next
    end
    tip = out.strip

    version = gem_version_from_ref(repo, tip)
    if version.empty?
      failures << "could not resolve a version for gem #{repo} at origin/#{RELEASE_BRANCH} — " \
                  "check #{repo}/#{gem_meta_for(repo)['version_file']}"
      next
    end

    if (stranded = stranded_gem_failure(repo, path, tip, version))
      failures << stranded
      next
    end

    if app_groups.any? && consumers.none? { |_, text| Release::ShipSequence.consumer_bump_action(text, repo, version) != :absent }
      failures << "gem #{repo} #{version} has no consuming app in this sweep (checked: " \
                  "#{consumers.keys.join(', ')}) — the published gem would assemble QA-green with QA never " \
                  "bundling it; enroll the consuming app (or eject the gem member)"
      next
    end

    plan << { "repo" => repo, "tip" => tip, "version" => version,
              "already_live" => !Release::ShipSequence.publish_needed?(version, rubygems_versions(repo)) }
  end

  if failures.any?
    abort!("gem publish preflight FAILED — NOTHING was published (every swept gem validates before the " \
           "first irreversible push):\n  - " + failures.join("\n  - "))
  end
  plan
end

# Phase 1's consumer read: each swept app's Gemfile AT origin/release, behind a
# FAIL-CLOSED fetch (the same stale-ref discipline as the gems). An app with no
# Gemfile at the tip simply cannot consume — that alone is not a failure; the
# per-gem coverage check above decides.
def validated_consumer_gemfiles(app_groups, failures)
  app_groups.each_with_object({}) do |group, gemfiles|
    repo = group["repo"]
    path = repo_path(repo)
    unless Dir.exist?(path)
      failures << "app repo not found at #{path} — clone it as a sibling at the projects root"
      next
    end
    _, fetched = sh("git", "-C", path, "fetch", "origin", "--quiet")
    unless fetched
      failures << "git fetch failed in #{repo} — refusing to preflight gem consumers against a " \
                  "possibly-stale origin/#{RELEASE_BRANCH} (fail closed)"
      next
    end
    text, ok = git_capture("-C", path, "show", "origin/#{RELEASE_BRANCH}:Gemfile")
    gemfiles[repo] = ok ? text : ""
  end
end

# PHASE 2 — the irreversible loop, run ONLY after phase 1 validated every swept
# gem. No new decisions here: the plan carries the tip, version, and live-state
# phase 1 resolved. Idempotent for the self-healing re-run: already-live
# versions skip.
def publish_gems_for_qa(gem_plan)
  return {} if gem_plan.empty?

  published = {}
  gem_plan.each do |gem|
    repo = gem["repo"]
    if gem["dry"]
      published[repo] = ""
      next
    end

    if gem["already_live"]
      say("  gem #{repo} #{gem['version']} already live on RubyGems — skip publish (idempotent re-run)")
    else
      step("  gem #{repo} #{gem['version']}: publish from origin/#{RELEASE_BRANCH} (#{short(gem['tip'])}) — " \
           "QA must test consumers against the REAL published artifact")
      checkout_detached(repo, gem["tip"]) # build from the exact release tree
      publish_gem(repo, gem["version"])   # reused: release-check → build → push → tag
      restore_gem_primary(repo)
    end
    published[repo] = gem["version"]
  end
  published
end

# The STRANDED-WORK guard for one gem repo (the pure decision + message live in
# Release::ShipSequence): origin/release ahead of the last published v* tag with
# an UNBUMPED version_file is the silent-skip hazard that stranded engine
# commits behind a green pipeline. Returns the loud failure message (naming the
# commits) for phase 1 to collect, or nil. A repo with no v* tag yet has
# nothing published to strand behind → no guard.
def stranded_gem_failure(repo, path, tip, version)
  tag_out, tag_ok = git_capture("-C", path, "describe", "--tags", "--abbrev=0", "--match", "v*", tip)
  return nil unless tag_ok # no published tag — first publish; nothing to strand behind

  tag = tag_out.strip
  ahead_out, ahead_ok = git_capture("-C", path, "log", "--oneline", "#{tag}..#{tip}")
  unless ahead_ok
    return "could not read #{repo} #{tag}..origin/#{RELEASE_BRANCH} for the stranded-work guard — " \
           "fetch, then re-run `bin/release prepare`"
  end

  commits = ahead_out.lines.map(&:chomp).reject { |l| l.strip.empty? }
  return nil unless Release::ShipSequence.stranded_gem_work?(
    ahead_commits: commits, version: version, tag_version: tag.delete_prefix("v")
  )

  Release::ShipSequence.stranded_gem_message(
    repo, ahead_commits: commits, version: version,
    version_file: gem_meta_for(repo)["version_file"],
    tag_version: tag.delete_prefix("v")
  )
end

# Bump each consumer's Gemfile.lock (and, only when the new version ESCAPES the
# existing constraint, its Gemfile pin) to the just-published gem versions —
# COMMITTED onto the consumer's origin/release, BEFORE the pre-QA gate and the
# QA deploy. That one commit is what makes the whole move sound: the pre-QA CI
# verdict targets the post-bump release SHA, QA bundles the new lock, and prod
# ships the exact tree QA tested (ship's repin then finds nothing to do).
#
# Built in the repo's ship workspace pinned at origin/release's tip (the same
# never-touch-the-primary mechanics as ship's repin_consumers), pushed by ref
# fast-forward-checked. Idempotent: a lock already at the published versions
# commits nothing; a consumer whose Gemfile never declares the gems is skipped.
def bump_consumer_locks_for_qa(app_groups, published_gems)
  return if published_gems.empty?

  gem_names = published_gems.keys
  step("bump consumer locks for #{gem_names.join(', ')} on origin/#{RELEASE_BRANCH} — " \
       "the pre-QA gate, QA, and prod must all build this SAME committed lock")
  app_groups.each do |group|
    repo = group["repo"]

    if DRY
      step("  #{repo}: bundle lock --update <gem> --conservative in the ship workspace @ origin/#{RELEASE_BRANCH} " \
           "(rewrite the Gemfile pin only if the new version escapes it) → commit + push origin #{RELEASE_BRANCH} " \
           "(idempotent; no-op when already current)")
      next
    end

    path = repo_path(repo)
    abort!("app repo not found at #{path} — clone it as a sibling at the projects root") unless Dir.exist?(path)
    _, fetched = sh("git", "-C", path, "fetch", "origin", "--quiet")
    abort!("git fetch failed in #{repo} — refusing to bump the consumer lock against a possibly-stale " \
           "origin/#{RELEASE_BRANCH} (fail closed); fix the remote, then re-run `bin/release prepare`") unless fetched
    out, ok = git_capture("-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}")
    abort!("could not resolve origin/#{RELEASE_BRANCH} in #{repo} for the consumer lock bump") unless ok
    tip = out.strip

    with_ship_workspace(repo) do
      workspace = ship_workspace!(repo, tip)
      ws_gemfile = File.join(workspace, "Gemfile")
      next unless File.exist?(ws_gemfile)

      text    = File.read(ws_gemfile)
      touched = gem_names.select do |gem_name|
        Release::ShipSequence.consumer_bump_action(text, gem_name, published_gems[gem_name]) != :absent
      end
      if touched.empty?
        say("  #{repo}: Gemfile does not declare #{gem_names.join(', ')} — no lock bump")
        next
      end

      expected = text.dup
      touched.each { |gem_name| expected = Release::ShipSequence.bumped_gemfile(expected, gem_name, published_gems[gem_name]) }
      File.write(ws_gemfile, expected) if expected != text
      touched.each { |gem_name| bundle_lock(workspace, gem_name, conservative: true) }

      status, = git_capture("-C", workspace, "status", "--porcelain", "--", "Gemfile", "Gemfile.lock")
      if status.to_s.strip.empty?
        say("  #{repo}: lock already at #{touched.map { |g| "#{g} #{published_gems[g]}" }.join(', ')} — nothing to commit (idempotent re-run)")
        next
      end

      bumps = touched.map { |g| "#{g} #{published_gems[g]}" }
      sh("git", "-C", workspace, "add", "Gemfile", "Gemfile.lock")
      _, committed = sh("git", "-C", workspace, "commit", "-m", "bump #{bumps.join(', ')} for QA", capture: true)
      abort!("could not commit the consumer lock bump in #{repo}'s ship workspace") unless committed

      # Push the detached commit onto `release` BY REF, fast-forward-checked (no
      # --force) — a release branch that moved under us fails closed here,
      # before the gate reads a SHA this bump isn't part of.
      _, pushed = sh("git", "-C", workspace, "push", "origin", "HEAD:refs/heads/#{RELEASE_BRANCH}", capture: true)
      abort!("could not push the consumer lock bump to origin/#{RELEASE_BRANCH} in #{repo} (did #{RELEASE_BRANCH} move?)") unless pushed

      step("  #{repo}: committed #{bumps.join(', ')} onto origin/#{RELEASE_BRANCH} — " \
           "the pre-QA gate + QA deploy now read the post-bump SHA")
    end
  end
end

# Best-effort: commit a generated doc (a `retro` doc or the `delete-later.md`
# ledger `archive` updates) onto `release` so it stops piling up as uncommitted dirt
# in the primary. NON-FATAL — any problem leaves the doc uncommitted (which no
# longer blocks anything: the ship deploys from its own workspace and only ADVISES
# on a dirty primary) and never aborts retro/archive. The IO seam around the pure
# Release::ArtifactCommit:
#   - commit ONLY when the doc is the SOLE uncommitted change (never sweep up dirt),
#   - build on origin/release's tip (ff-only) so the push fast-forwards and the NEXT
#     ship's `main` ref push carries it — no main/release divergence,
#   - ALWAYS restore the checkout to `main` (ensure), even on failure,
#   - SKIP (doc stays uncommitted) when another invocation holds the primary
#     checkout — never flip HEAD under a running pre-QA gate suite
#     (with_primary_checkout, wait: false).
def commit_artifact_to_release(repo, abs_path, message)
  return if DRY

  path = repo_path(repo)
  rel  = abs_path.to_s.delete_prefix("#{path}/")

  status, ok = git_capture("-C", path, "status", "--porcelain")
  unless ok && Release::ArtifactCommit.safe_to_commit?(status, rel)
    step("left #{rel} uncommitted (#{ok ? 'other changes present' : 'git status failed'}) — commit it via a docs PR")
    return
  end

  sh("git", "-C", path, "fetch", "origin", RELEASE_BRANCH, "--quiet", capture: true)

  # BEST-EFFORT lock (wait: false): if another invocation holds the primary
  # checkout, SKIP rather than stall archive/retro behind it, and NEVER flip HEAD
  # under a running suite (the rel-20260708-496cd8 false-negative G3). The doc
  # simply stays uncommitted — a non-fatal fallback that costs nothing now: a dirty
  # primary no longer blocks a ship, it only earns an advisory.
  done = false
  res = with_primary_checkout(repo, wait: false) do
    _, co = sh("git", "-C", path, "checkout", RELEASE_BRANCH, capture: true)
    if co
      _, ff = sh("git", "-C", path, "merge", "--ff-only", "origin/#{RELEASE_BRANCH}", capture: true)
      if ff
        sh("git", "-C", path, "add", "--", rel, capture: true)
        _, committed = sh("git", "-C", path, "commit", "-m", message, capture: true)
        _, done = sh("git", "-C", path, "push", "origin", RELEASE_BRANCH, capture: true) if committed
      end
    end
  ensure
    sh("git", "-C", path, "checkout", "main", capture: true)
  end
  if res == :busy
    step("left #{rel} uncommitted (primary checkout busy — a concurrent bin/release gate/ship holds #{repo}) — commit it via a docs PR")
    return
  end

  step(done ? "committed #{rel} to #{RELEASE_BRANCH} (ships on the next release)" \
            : "left #{rel} uncommitted (commit/push failed) — commit it via a docs PR")
end

# Publish (or idempotently skip) one gem, then collapse its release → main at the
# frozen SHA. Skip when the version is already LIVE. Yank safety is delegated to
# `gem push` failing closed: a yanked number isn't in the listing → publish_needed?
# is true → we try to push → RubyGems rejects re-pushing it → publish_gem aborts,
# BEFORE any app deploys. Records the gem as live for the partial report.
# `member_slugs` are the gem's release members — stamped `merged: "main"` once the
# ff lands on origin (the interrupted-Avi crash-recovery signal).
def ship_gem(repo, version, frozen, member_slugs = [])
  abort!("could not resolve a version for gem #{repo} — check #{repo}/#{gem_meta_for(repo)['version_file']}") if version.empty? && !DRY

  if DRY
    step("gem #{repo} #{version}: publish to RubyGems from #{short(frozen)} " \
         "(skip if already live) → tag v#{version} → push #{repo} origin main → #{short(frozen)}")
    return
  end

  remote = rubygems_versions(repo)
  if !Release::ShipSequence.publish_needed?(version, remote)
    say("  gem #{repo} #{version} already live on RubyGems — skip publish (idempotent)")
  else
    # No listing-based yank check: the versions API omits yanked versions entirely
    # (no `yanked` field), so yank protection is delegated to `gem push` failing
    # closed — RubyGems forbids re-pushing a yanked number, so publish_gem aborts
    # loudly here (BEFORE any app deploy) if `version` was yanked.
    checkout_detached(repo, frozen) # build the artifact from the QA-frozen commit
    publish_gem(repo, version)      # reused: release-check → build → push → tag
  end
  @ship_live << "gem #{repo} #{version} live on RubyGems"
  push_frozen_main(repo, frozen)
  # The artifact build left the primary DETACHED at the frozen SHA (checkout_detached
  # — gems are the one repo class still built from their primary). Put it back on
  # main, best-effort: the gem is already published, so a checkout that won't restore
  # must never abort the train.
  restore_gem_primary(repo)
  record_merged_main(member_slugs)
end

# Is origin/release's head THIS RUN'S OWN re-pin of `frozen`, already pushed by a
# ship that died partway (so the retry must REUSE it, not mint a rival)? The I/O seam
# for Release::ShipSequence.resumable_repin? — it gathers the three facts and the
# pure model decides. All three reads run in the SHIP WORKSPACE, which shares the
# primary's object store, so the just-fetched origin/release commit resolves there.
#
# Any read that fails answers FALSE — never "probably fine". The caller then aborts
# as un-QA'd drift, which is the correct fail-closed direction: refusing a resumable
# ship costs a conversation, completing an unresumable one costs production.
def resumable_repin?(repo, workspace, frozen:, head:, expected_gemfile:)
  # 1. ANCESTRY — head is frozen PLUS something, not a divergent line.
  _, ancestor = sh("git", "-C", workspace, "merge-base", "--is-ancestor", frozen, head, capture: true)
  return false unless ancestor

  # 2. SHAPE — that something touches ONLY Gemfile/Gemfile.lock (no code rides out).
  diff, diff_ok = git_capture("-C", workspace, "diff", "--name-only", frozen, head)
  return false unless diff_ok

  # 3. IDENTITY — its Gemfile is byte-identical to what this run would write.
  gemfile, gemfile_ok = git_capture("-C", workspace, "show", "#{head}:Gemfile")
  return false unless gemfile_ok

  Release::ShipSequence.resumable_repin?(
    ancestor: true,
    changed_files: diff.to_s.lines,
    head_gemfile: gemfile,
    expected_gemfile: expected_gemfile
  )
end

# Auto-re-pin (D1): after ALL gems are live, before any app deploys, re-pin each
# consumer's branch-ref'd gem line to the published `~> x.y` so prod builds
# against the release, not a branch. Idempotent (already-pinned → no-op). One
# pass per consumer; the re-pin commit ships on TOP of the frozen SHA (so only
# frozen + the mechanical re-pin reach prod — guarded against un-QA'd drift).
#
# It builds that commit in the SHIP WORKSPACE, not the primary. It used to
# `git checkout release` in the shared primary, write the Gemfile there, commit and
# push — a checkout flip plus a commit in a tree a feature session may be using,
# which is why the ship had to refuse a dirty primary in the first place. The
# workspace is already pinned (detached) at the frozen SHA — exactly the base this
# commit must sit on — so the commit is built there and pushed by ref
# (`HEAD:refs/heads/release`, fast-forward-checked). The primary is never touched
# and never even read.
def repin_consumers(app_groups, published_gems, ship_sha)
  return if published_gems.empty?

  gem_names = published_gems.keys
  step("auto-repin consumers of #{gem_names.join(', ')} → ~> x.y (after all gems live, before any deploy)")
  app_groups.each do |group|
    repo = group["repo"]
    path = repo_path(repo)

    if DRY
      step("  #{repo}: re-pin any branch-ref'd published gem in Gemfile (ship workspace @ frozen) → " \
           "bundle lock --update → commit + push origin #{RELEASE_BRANCH} (idempotent; no-op if already pinned)")
      next
    end

    with_ship_workspace(repo) do
      workspace = ship_workspace!(repo, ship_sha[repo])

      # The workspace HEAD must BE the frozen SHA. It is by construction (it was
      # just reset --hard onto it), so this asserts the pin actually took rather
      # than trusting it: EVERY decision and edit below reads this tree, commits on
      # this HEAD, and pushes it to `release`, so a wrong HEAD here would ship
      # un-QA'd code. (The old check was the same invariant on the primary's local
      # `release` branch, where an un-pushed local commit could sit.)
      local_head, local_ok = git_capture("-C", workspace, "rev-parse", "HEAD")
      abort!("could not read the ship workspace HEAD in #{repo} for re-pin") unless local_ok
      if local_head.strip != ship_sha[repo]
        abort!("#{repo} ship workspace HEAD (#{short(local_head.strip)}) is not the QA-frozen SHA " \
               "(#{short(ship_sha[repo])}) — REFUSING to build the re-pin on the wrong base")
      end

      # DECIDE FROM THE FROZEN TREE — never from the primary.
      #
      # This read used to come from the PRIMARY's Gemfile, and it was safe only
      # because of two things this change removed: the ship ff'd the primary's `main`
      # to the frozen SHA, and the preflight refused a dirty/off-main primary. With
      # the invariant gone, a primary read is a silent, prod-affecting lie in BOTH
      # directions (carl, PR #517):
      #   * The primary's `main` is now one release behind BY DEFINITION (nothing
      #     ff's it). If the FROZEN tree branch-refs a gem while the primary's stale
      #     main still carries the previous `~> x.y` pin, the decision comes back
      #     EMPTY, prints a reassuring "already pinned", and the app DEPLOYS A FROZEN
      #     SHA WHOSE GEMFILE STILL POINTS AT A GIT BRANCH — prod building the gem
      #     from a branch instead of the published version, which is the exact hazard
      #     auto-re-pin exists to prevent. It FAILS GREEN.
      #   * The mirror: a dirty/feature-branch primary that branch-refs a gem the
      #     frozen tree already pinned would make the rewrite a no-op, stage nothing,
      #     and abort at the commit — AFTER THE GEMS PUBLISHED.
      # The tree the re-pin is built ON is the only tree entitled to decide whether
      # it is needed.
      ws_gemfile = File.join(workspace, "Gemfile")
      next unless File.exist?(ws_gemfile)

      frozen  = ship_sha[repo]
      text    = File.read(ws_gemfile)
      pending = Release::ShipSequence.gems_to_repin(gem_names, text)
      if pending.empty?
        say("  #{repo}: Gemfile at the frozen SHA is already pinned for #{gem_names.join(', ')} — no re-pin")
        next
      end

      # EXACTLY what this run would write — computed up front, because it is both the
      # content we are about to commit AND the identity a prior partial ship's re-pin
      # must match to be reusable (see below).
      expected = text.dup
      pending.each { |gem| expected = Release::GemfileRepin.rewrite(expected, gem, published_gems[gem]) }

      # The re-pin must build on the QA-frozen SHA. Fetch first so the origin check
      # reads the TRUE remote (not a stale local origin/release ref), then require
      # origin/release == frozen so a post-prepare merge to origin can't sneak out
      # un-QA'd under cover of the re-pin. (A ref read + a fetch — no working tree.)
      _, fetched = sh("git", "-C", path, "fetch", "origin", "--quiet")
      abort!("could not fetch origin in #{repo} for re-pin — check the remote, then re-run `bin/release ship`") unless fetched

      head, ok = git_capture("-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}")
      abort!("could not read origin/#{RELEASE_BRANCH} in #{repo} for re-pin") unless ok
      head = head.strip

      if head != frozen
        # origin/release MOVED. Before calling that un-QA'd drift, ask the only
        # question that matters: IS IT THIS RUN'S OWN RE-PIN, already pushed by a
        # ship that published the gems and then died? (Release::ShipSequence —
        # ancestry + Gemfile/Gemfile.lock-only + a BYTE-IDENTICAL Gemfile.) If it is,
        # the act is already done: ship THAT commit rather than mint a rival with the
        # same tree, which is what wedged the retry — its push is non-fast-forward
        # against the re-pin already on the branch, and the ship could never complete.
        if resumable_repin?(repo, workspace, frozen: frozen, head: head, expected_gemfile: expected)
          say("  #{repo}: the re-pin for #{short(frozen)} is ALREADY on origin/#{RELEASE_BRANCH} " \
              "(#{short(head)}) — a prior partial ship pushed it. REUSING that commit (minting a second " \
              "one would be a non-fast-forward and could never land).")
          @ship_live << "re-pin already live on origin/#{RELEASE_BRANCH} in #{repo} (#{short(head)})"
          ship_sha[repo] = head
          next
        end

        abort!("#{repo} origin/#{RELEASE_BRANCH} (#{short(head)}) drifted past the QA-frozen SHA " \
               "(#{short(frozen)}), and the drift is NOT this run's own re-pin (it changes more than " \
               "Gemfile/Gemfile.lock, or its Gemfile is not what this ship would write) — so code would " \
               "reach production un-QA'd. Re-run `bin/release prepare` to re-QA before re-pinning.")
      end

      File.write(ws_gemfile, expected)
      text = expected
      pending.each { |gem| bundle_lock(workspace, gem) }

      pins = pending.map { |gem| "#{gem} #{Release::GemfileRepin.pessimistic_constraint(published_gems[gem])}" }
      sh("git", "-C", workspace, "add", "Gemfile", "Gemfile.lock")
      _, committed = sh("git", "-C", workspace, "commit", "-m", "repin #{pins.join(', ')}", capture: true)
      abort!("could not commit the re-pin in #{repo}'s ship workspace") unless committed

      # Push the detached commit onto `release` BY REF. Fast-forward-checked (no
      # --force), so a release branch that moved under us fails closed here — before
      # any app deploys.
      _, pushed = sh("git", "-C", workspace, "push", "origin", "HEAD:refs/heads/#{RELEASE_BRANCH}", capture: true)
      abort!("could not push the re-pin to origin/#{RELEASE_BRANCH} in #{repo} (did #{RELEASE_BRANCH} move?)") unless pushed

      new_head, = git_capture("-C", workspace, "rev-parse", "HEAD")
      ship_sha[repo] = new_head.strip # ship the re-pin commit (frozen + re-pin)
      @ship_live << "re-pinned #{pins.join(', ')} in #{repo}"
    end
  end
end

# "What's already live" pre-flight (live-only reads): per repo, is the gem
# version already on RubyGems / is the app's main already at the frozen SHA?
# Informational — the single confirm follows. A dry-run prints the plan instead.
def whats_live(repos, qa_shas)
  return if DRY

  say("")
  say("  Pre-flight — what's already live:")
  repos.each do |group|
    repo = group["repo"]
    if group["kind"] == "gem"
      version = gem_version_for(repo, group, frozen_sha_for(repo, qa_shas))
      live    = !Release::ShipSequence.publish_needed?(version, rubygems_versions(repo))
      say("    gem #{repo} #{version}: #{live ? 'LIVE on RubyGems — will skip' : 'not published — will publish'}")
    else
      # The LAST-KNOWN origin/main — the ref the ship actually advances
      # (push_frozen_main). Reading the LOCAL `main` here would report on a branch
      # nothing in the deploy depends on any more (the ship stopped ff'ing it).
      #
      # Deliberately NOT fetched. Nothing else in the ship path fetches now (the old
      # ff_main_local did), so this ref can be stale — but this is an INFORMATIONAL
      # pre-flight report, and a fetch here would put network I/O into a line that
      # decides nothing. If it is stale the report merely says "will ff" for a repo
      # already at the frozen SHA; the push itself is a harmless no-op. The
      # AUTHORITATIVE check is push_frozen_main, which is fast-forward-checked
      # server-side and fails closed on a genuinely diverged main.
      frozen        = qa_shas[repo].to_s
      main_sha, ok  = git_capture("-C", repo_path(repo), "rev-parse", "origin/main")
      at            = ok && !frozen.empty? && main_sha.strip == frozen
      say("    app #{repo}: origin/main (last known) #{at ? "already at #{short(frozen)}" : "will ff → #{short(frozen)}"}")
    end
  end
end

# Avi's ship gate: run each app's full local suite (registry `test_cmd` — the
# full-suite tier, Release::STEP_TEST_TIERS["ship"]) on the FROZEN ship SHA —
# the exact code that ships — BEFORE the ship-authority gate, so approval can
# never authorize untested code (§1.2 "fixes shipped ≠ tested"). A red gate
# scoped-aborts before the confirm. Satellites self-gate (their own deploy runs
# their suite) → no `test_cmd` → skipped; a repo whose frozen SHA the G3 gate
# already certified with the same command self-gates too (see test_gate),
# recording the skip as a gate SOP.
#
# IT MUTATES NOTHING. It used to fast-forward each app's `main` in the primary
# first, so the suite could run on the frozen tree — but the suite MOVED to the
# isolated gate workspace (pinned at the frozen SHA, its own test DB), which is a
# strictly better tree to certify, so the ff became vestigial: it took the
# primary-checkout lock, flipped a shared checkout, and no longer fed anything.
# Dropping it means NOTHING in the ship — not a ref, not a checkout, not a lock —
# is touched before ship authority. A red gate or a declined confirm now leaves
# the entire machine exactly as it found it.
def avi_ship_gate(app_groups, ship_sha, qa_gates)
  say("")
  step("Avi ship gate: full suite (registry test_cmd) on the FROZEN ship SHA " \
       "(isolated workspace, before ship authority — nothing is mutated yet)")
  app_groups.each do |group|
    repo = group["repo"]
    test_gate(repo, frozen_sha: ship_sha[repo],
                    qa_gate: Release::ShipSequence.qa_gate(qa_gates, repo))
  end
end

# Deploy one app to prod via its registry adapter. Common prelude: advance
# origin/main to the frozen SHA (a ref push — the test gate already ran in
# avi_ship_gate, before ship authority). Then the strategy-specific mechanic +
# smoke policy.
#
# NOTHING HERE READS THE PRIMARY'S WORKING TREE. That is the whole point of this
# region (2026-07-12): ask what the deploy actually NEEDS, and the answer splits
# cleanly in two.
#
#   * git_push_heroku (hub, rolio) needs NO WORKING TREE. "Deploy" is: hand a
#     commit to a git remote. So it is a ref push straight out of the shared object
#     store — `git push <remote> <frozen>:refs/heads/<branch>` — which is also
#     STRICTER than what it replaced: the old `git push heroku main` shipped
#     whatever the local `main` branch pointed at (correct only because an ff had
#     just moved it, in a checkout any concurrent session could disturb); this
#     ships the frozen SHA BY VALUE. Non-fast-forward is still refused by git (no
#     --force, ever), so a diverged remote fails closed exactly as before.
#
#   * repo_script (turf-monster) DOES need a working tree — its bin/deploy runs
#     the repo's own suite, hashes config/*.idl.json for the IDL pin, and pushes
#     from the checkout it runs in. It gets the SHIP WORKSPACE: a private detached
#     worktree pinned at the frozen SHA, prepared like a gate (bundle + a test DB
#     proven private), under the ship-workspace lock.
#
#     VERIFIED, not assumed (this is the assumption class that caused the bug being
#     fixed here): turf's bin/deploy computes `BRANCH=$(git rev-parse --abbrev-ref
#     HEAD)`, which in a DETACHED worktree is the literal "HEAD", and then pushes
#     `PUSH_SPEC="$BRANCH:main"` → `git push heroku-mainnet HEAD:main` — i.e. it
#     pushes the frozen commit to the Heroku app's main. Its `git remote get-url`
#     resolves because a linked worktree SHARES the repo config (no
#     extensions.worktreeConfig anywhere here), its `git diff-index --quiet HEAD`
#     clean-tree preflight passes (a freshly reset workspace is clean — where a
#     shared primary might not be), and the IDL files it hashes are TRACKED, so
#     they are present in the workspace. The one cosmetic difference is a "Not on
#     main (current: HEAD)" warn, which does not affect its exit status.
# --- resumable ship: is a group's frozen SHA ALREADY live on prod? -----------
# The I/O half of Release::ShipSequence.deploy_already_succeeded? — it gathers the
# live signals a killed watcher lost and hands them to the pure decision. Two
# callers: deploy_app skips a redundant re-dispatch on a `ship` RE-RUN, and
# `finalize` GUARDS against marking `shipped` a release that never deployed.
#
# All READS (they mutate nothing), so they run for real even in --dry-run — the
# same "a read previews without mutating" contract as git_capture / conductor
# (read_only:). They deliberately DO NOT go through `sh` (which would print
# "[dry-run]" and skip), so a dry-run finalize can preview the real verdict.
#   * origin/main via `git ls-remote` — the AUTHORITATIVE remote ref (never a
#     local branch: the ship no longer moves the primary's local main).
#   * prod /up via curl.
#   * github_actions ONLY: the deploy workflow's recent runs, scanned for a
#     completed+success run AT the frozen SHA (prod_run_succeeded?).
def origin_main_sha(repo)
  out, ok = git_capture("-C", repo_path(repo), "ls-remote", "origin", "refs/heads/main")
  ok ? out.to_s.split(/\s+/).first.to_s.strip : ""
end

def prod_up_ok?(base_url)
  url = base_url.to_s.strip
  return false if url.empty?

  out, status = Open3.capture2e("/usr/bin/curl", "-s", "-o", "/dev/null",
                                "-w", "%{http_code}", "#{url}/up")
  status.success? && out.strip == "200"
end

def deploy_workflow_runs(workflow, path)
  wf = workflow.to_s.strip
  return [] if wf.empty?

  out, status = Open3.capture2e("gh", "run", "list", "--workflow", wf, "--limit", "20",
                                "--json", "databaseId,headSha,status,conclusion", chdir: path)
  return [] unless status.success?

  JSON.parse(out)
rescue JSON::ParserError
  []
end

# The prod smoke URL for a group: the adapter's smoke_url, or the hub's PROD_URL
# for github_actions (its adapter keeps smoke_url for the board, and the hub IS
# PROD_URL). Blank → prod_up_ok? returns false (fail closed).
def group_smoke_url(group)
  adapter = group["prod_deploy"] || {}
  smoke = adapter["smoke_url"].to_s.strip
  return smoke unless smoke.empty?

  group["repo"] == APP ? PROD_URL.to_s : ""
end

# Decide — over live signals — whether `group`'s frozen SHA is genuinely deployed.
# Fails closed on any unreadable signal. deployed_at_sha (the repo_script marker)
# is left nil for now: turf's mainnet-release marker read is a future tightening,
# so a repo_script re-run re-dispatches (safe — its bin/deploy self-gates).
def deploy_already_live?(group, frozen)
  frozen = frozen.to_s.strip
  return false if frozen.empty?

  adapter  = group["prod_deploy"] || {}
  strategy = adapter["strategy"].to_s
  run_success =
    if strategy == "github_actions"
      Release::ShipSequence.prod_run_succeeded?(
        deploy_workflow_runs(adapter["workflow"], repo_path(group["repo"])), frozen
      )
    end

  Release::ShipSequence.deploy_already_succeeded?(
    strategy: strategy,
    up_ok: prod_up_ok?(group_smoke_url(group)),
    main_at_sha: origin_main_sha(group["repo"]) == frozen,
    run_success: run_success
  )
end

def deploy_app(group, frozen)
  @ship_live ||= [] # ship() seeds this; never let a nil deref be the way a deploy fails
  repo    = group["repo"]
  path    = repo_path(repo)
  adapter = group["prod_deploy"] || {}
  handler =
    begin
      Release::ShipSequence.strategy_handler(adapter["strategy"])
    rescue ArgumentError => e
      abort!(e.message)
    end

  say("")
  step("app #{repo} → prod via #{adapter['strategy']} @ frozen #{short(frozen)}")

  push_frozen_main(repo, frozen)
  # The ff landed on origin — stamp this repo's members merged:"main" (matrix:
  # assembled+main = prod-in-flight; an interrupted re-run reads it as "ff done").
  record_merged_main(Array(group["members"]).map { |m| m["slug"] })

  # RESUMABLE SHIP (fix option b): on a RE-RUN after a watcher-process kill left the
  # deploy landed but the ship stranded, skip re-dispatching a deploy that ALREADY
  # concluded success — a re-dispatch would demand a 2nd `production` Environment
  # approval and re-run the whole deploy for nothing. Only skips on affirmative,
  # strategy-appropriate proof (deploy_already_live? → ShipSequence.deploy_already_
  # succeeded?, which fails closed); anything less falls through to a normal deploy.
  # Gated on !DRY so a dry-run preview always shows the full dispatch plan.
  if !DRY && deploy_already_live?(group, frozen)
    step("deploy: #{repo} ALREADY live at frozen #{short(frozen)} (prod-deploy previously concluded success) — skipping re-dispatch")
    gate_sop("deploy:#{repo}", "skip re-dispatch (already deployed @ #{short(frozen)})", true, 0)
    @ship_live << "app #{repo} already deployed to production (resumed — re-dispatch skipped)"
    return
  end

  case handler
  when :git_push_heroku
    remote = adapter["remote"] || HEROKU_REMOTE
    branch = adapter["branch"] || "main"
    step("deploy: git -C #{repo} push #{remote} #{short(frozen)}:refs/heads/#{branch} (ref push — no checkout)")
    deploy_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    _, ok = DRY ? [nil, true] : sh("git", "-C", path, "push", remote, "#{frozen}:refs/heads/#{branch}", capture: false)
    # The G4 gate's per-app deploy SOP — recorded BEFORE the abort so a failed
    # push still shows on the gate run the SystemExit wrapper closes.
    gate_sop("deploy:#{repo}", "git push #{remote} #{short(frozen)}:refs/heads/#{branch}", ok || DRY,
             ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - deploy_started) * 1000).round)
    abort!("Heroku deploy failed for #{repo}") unless ok || DRY

    smoke = adapter["smoke_url"].to_s
    if smoke.empty?
      say("  (no smoke_url for #{repo} — smoke skipped)")
    else
      step("smoke: GET #{smoke}/up")
      # Block form so the emitted pass/fail reflects the HTTP code, not curl's
      # exit (curl exits 0 even on a 500 with -o/-w); abort semantics unchanged.
      code, = run_test_scope("prod_up_smoke", repo: repo, label: "curl #{smoke}/up") do
        out, = sh("/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "#{smoke}/up", capture: true)
        [out, out.strip == "200"]
      end
      say("  /up → #{code}") unless DRY
      abort!("smoke failed for #{repo} (#{smoke}/up != 200)") if !DRY && code.strip != "200"
    end
  when :repo_script
    command = adapter["command"].to_s
    args    = Array(adapter["args"])
    abort!("repo_script adapter for #{repo} has no `command`") if command.empty? && !DRY
    step("deploy: (cd #{repo} ship workspace @ frozen #{short(frozen)}) #{command} #{args.join(' ')} " \
         "— repo owns its smoke + rollback")
    if DRY
      gate_sop("deploy:#{repo}", "#{command} #{args.join(' ')}".strip, true, 0)
      @ship_live << "app #{repo} deployed to production"
      return
    end

    deploy_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ok = false
    # Under the SHIP-workspace lock (never the gate's, never the primary's): the
    # path is fixed, so a concurrent conductor could otherwise reset the tree — or
    # purge its DB — under a live production deploy.
    with_ship_workspace(repo) do
      workspace = ship_workspace!(repo, frozen)
      prepare_ship_workspace!(repo, workspace)
      # Refresh the index's stat cache before handing the tree to the repo's deploy
      # script. Our OWN prep dirties the stat cache without changing content: the
      # `reset --hard` writes files + index in the same clock-second (racy git), and
      # `db:test:prepare`/`bundle` bump tracked files' mtimes (a byte-identical
      # Gemfile.lock rewrite; a rails-boot touch). A deploy script that gates on
      # `git diff-index --quiet HEAD` (turf's bin/deploy) then misreads the stat-stale
      # tree as "uncommitted changes" and refuses a legitimate ship. `update-index
      # --refresh` re-hashes ONLY the stat-dirty entries and clears those whose content
      # is unchanged — a genuine content diff stays dirty (and is reported), so this
      # corrects the false positive without hiding real dirt. Never reset/checkout here.
      sh("git", "-C", workspace, "update-index", "-q", "--refresh", capture: true)
      # ship_deploy_env, NOT gate_env: a production deploy script gets its private
      # test DB and nothing else — no RAILS_ENV=test, no ruby pin. See ship_deploy_env.
      _, ok = sh(command, *args, chdir: workspace, env: ship_deploy_env(repo))
    end
    # The G4 gate's per-app deploy SOP (see the git_push_heroku twin above).
    gate_sop("deploy:#{repo}", "#{command} #{args.join(' ')}".strip, ok,
             ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - deploy_started) * 1000).round)
    abort!("#{repo} deploy script failed (#{command}) — its own rollback applies; fix + re-run `bin/release ship`") unless ok
  when :github_actions
    # DevOps v2 Phase 2 (the hub): the Heroku push AND the hard /up smoke run
    # INSIDE the dispatched workflow, so there is NO separate conductor curl-smoke
    # here — dispatch_and_watch's success return already means "deployed AND
    # smoked green". push_frozen_main above still advanced origin/main by ref; the
    # workflow deploys the frozen SHA it is handed, independent of that push (which
    # is exactly why prod-deploy.yml is workflow_dispatch, not push:[main]).
    workflow = adapter["workflow"].to_s
    abort!("github_actions adapter for #{repo} has no `workflow`") if workflow.empty? && !DRY
    step("deploy: gh workflow run #{workflow} -f sha=#{short(frozen)} — GitHub Actions does the Heroku push + hard /up smoke")
    deploy_started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ok = dispatch_and_watch(workflow, { "sha" => frozen }, chdir: path)
    gate_sop("deploy:#{repo}", "gh workflow run #{workflow} -f sha=#{short(frozen)}", ok || DRY,
             ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - deploy_started) * 1000).round)
    abort!("GitHub Actions prod deploy failed for #{repo} (#{workflow}) — check the run; fix + re-run `bin/release ship`") unless ok || DRY
  end
  @ship_live << "app #{repo} deployed to production"
end

# --- ship preflight: prove the ship can build its own trees -----------------
# WHAT THIS USED TO BE, and why it changed (2026-07-12). ship ff'd each app repo's
# `main` in the SHARED PRIMARY and ran the satellites' bin/deploy there, so the
# preflight REFUSED any app primary that was dirty or off `main`. That refusal
# ABORTED a production ship — after the gems had already published — because a
# concurrent feature session had staged work in the primary. The work could not be
# discarded (it was a live session's), so recovery meant a delicate
# stash-to-a-labeled-branch rescue at the worst possible moment.
#
# The deploy no longer reads those trees (push_frozen_main is a ref push;
# repo_script runs in the ship workspace), so an app primary's state is simply not
# input any more, and refusing on it would be theatre. What this step does now:
#
#   1. MATERIALIZE each app's ship workspace at the frozen SHA — the tree the
#      deploy will actually use — BEFORE anything is published or pushed. If a
#      worktree can't be created or pinned, the ship aborts HERE, where nothing is
#      live yet, instead of mid-train.
#   2. GATE the gem repos: a gem artifact is built from its primary and `gem build`
#      packages what is ON DISK, so a modified TRACKED file there would be
#      PUBLISHED. That is the one primary-state hazard left, and it is genuinely
#      unrecoverable (RubyGems forbids re-pushing a version) — so it aborts, and
#      the abort PRINTS THE RESCUE (commit the stranded work to a labeled branch;
#      never stash, never discard).
#   3. ADVISE on any dirty/off-main app primary — a note plus the same rescue,
#      never a blocker.
# The PURE decisions (offenders, advisory, rescue) live in Release::ShipSequence;
# this owns only the git reads. A dry-run prints the plan and runs NO git (so a
# preview never aborts on a legitimately-dirty dev sibling).

# The current branch + dirty-file list for a checkout (live git reads). Split out
# as the I/O seam ship_preflight calls per repo (stubbed in tests).
#
# `tracked_dirty` is the subset that would be PACKAGED by `gem build` — porcelain
# lines that are NOT "??" (untracked). Untracked files are invisible to the
# gemspec's `git ls-files`, so they are not a publish hazard and must not gate a
# ship; a modified tracked file is both.
def repo_git_state(repo, path)
  branch, = git_capture("-C", path, "rev-parse", "--abbrev-ref", "HEAD")
  status, = git_capture("-C", path, "status", "--porcelain")
  lines   = status.to_s.lines.map(&:chomp).reject { |l| l.strip.empty? }
  files   = lines.map { |l| l[3..].to_s.strip }.reject(&:empty?)
  tracked = lines.reject { |l| l.start_with?("??") }.map { |l| l[3..].to_s.strip }.reject(&:empty?)
  { "repo" => repo, "branch" => branch.to_s.strip, "dirty" => files.any?,
    "dirty_files" => files, "tracked_dirty" => tracked }
end

def ship_preflight(app_groups, gem_groups = [], ship_sha = {})
  say("")
  step("ship preflight: pin each app's ship workspace at its frozen SHA; check the gem builds")
  if DRY
    gem_groups.each { |g| say("  [dry-run] check #{g['repo']} (#{repo_path(g['repo'])}) has no modified tracked files (it is BUILT from its primary)") }
    app_groups.each { |g| say("  [dry-run] pin #{g['repo']} ship workspace (#{Release::GateWorkspace.path(repo_path(g['repo']), role: 'ship')}) at the frozen SHA") }
    return
  end

  # 1. The GEM gate — the one primary-state hazard that survives, because a gem is
  #    built from its primary checkout. Aborts BEFORE anything is published.
  gem_states = gem_groups.map { |g| repo_git_state(g["repo"], repo_path(g["repo"])) }
  gem_dirt   = Release::ShipSequence.gem_build_offenders(gem_states)
  abort!(Release::ShipSequence.gem_build_message(gem_dirt, root: projects_root)) if gem_dirt.any?

  # 2. Prove every app's ship workspace materializes at the frozen SHA NOW — an
  #    env failure (no disk, a wedged worktree registration) aborts here, where the
  #    release is still fully recoverable, rather than after the gems went out.
  app_groups.each do |group|
    repo = group["repo"]
    with_ship_workspace(repo) { ship_workspace!(repo, ship_sha[repo]) }
  end
  say("  ✓ #{app_groups.size} app ship workspace(s) pinned at the frozen SHA — the deploy runs from these, " \
      "not from the primaries")

  # 3. The app primaries: a NOTE, never a blocker. The ship does not read them.
  app_states = app_groups.map { |g| repo_git_state(g["repo"], repo_path(g["repo"])) }
  advisory   = Release::ShipSequence.advisory_message(
    Release::ShipSequence.preflight_offenders(app_states), root: projects_root
  )
  say(advisory) if advisory
end

# --- step 5c: production smoke SEAL -----------------------------------------
# AFTER every app deployed + the existing `/up` hard-gate passed (deploy_app), run
# the read-only @qa-readonly suite against PROD (bin/prod-smoke) and record a
# 🟢/🔴 SEAL on the release. A SEAL, NOT a gate: the deploy already happened, so a
# red seal ALERTS + prints the EXACT rollback but NEVER aborts the ship or
# auto-rolls-back — the operator stays the gate. Smokes the HUB only (the
# @qa-readonly spec is the hub's; turf owns its own bin/post_deploy_smoke).
#
# Runs BEFORE step 6's post_release_notes so the notes/Discord/board all read the
# SAME verdict (the seal write commits here; step 6 reloads the release by slug). The
# WRITE is best-effort: a prod-board blip on the seal record warns + continues —
# the red alert still prints from the LOCAL verdict, independent of the write.
#
# Returns the seal status ("passed"/"failed"), or nil when there was nothing to
# seal — the G4 gate close records it as metadata.seal (the seal is G4's
# NON-blocking closing beat: a red seal rides in sops + metadata but never
# flips the gate's success, exactly as it never aborts the ship).
def production_smoke_seal(app_groups, ship_sha, rel_slug)
  step("production smoke seal: bin/prod-smoke #{APP} (@qa-readonly vs prod) — post-ship SEAL, non-blocking")

  # Seal what we DEPLOYED: only when the hub (mcritchie-studio, whose @qa-readonly
  # spec this is) was actually part of this ship. A gem-only / satellite-only ship
  # changes nothing on the hub, so there is nothing to seal.
  unless app_groups.any? { |g| g["repo"] == APP }
    say("  (#{APP} not deployed in this ship — nothing to seal; skipped)")
    return nil
  end
  unless PROD
    say("  (local ship — the seal smokes the LIVE prod host only; skipped)")
    return nil
  end
  if DRY
    say("  [dry-run] bin/prod-smoke #{APP} → record 🟢/🔴 seal on #{rel_slug} (non-blocking)")
    return nil
  end

  record_release_event(rel_slug, "prod_smoke", "started")
  # ANCHOR the script to the hub checkout: bin/prod-smoke is cwd-relative, and a
  # ship run from outside the hub (rel-20260705-8fe04b ran from the projects
  # root) made Open3 raise Errno::ENOENT — aborting AFTER the prod deploy but
  # BEFORE step 6's Conductor.ship!, stranding the board at `assembled`. Every
  # other repo-scoped command resolves via repo_path; so does the seal now.
  # And because the seal is non-blocking BY CONTRACT (see above), an
  # unresolvable/missing script DEGRADES to a red seal instead of raising —
  # Open3 raises SystemCallError on a bad path, it never returns ok=false.
  # BOOT-WINDOW RETRY (rel-20260720-c06235): this seal runs seconds after the
  # Actions deploy, and a smoke landing inside the dyno boot/restart window can
  # fail against a HEALTHY prod (GET /tasks non-OK; 5/5 green on re-run). So on
  # a first failure Release::SealRetry waits ~30s and retries ONCE — only a
  # PERSISTING failure seals red, and a first-attempt pass never sleeps. The
  # retry is CALLER-SIDE so bin/prod-smoke stays an honest single-shot tool;
  # the seal's contract is unchanged — non-blocking, never auto-rolls-back.
  # The VERDICT composition (retry + seal + summary) lives in Release::SealRun so
  # it is testable on real objects; this script keeps the IO — chdir, capture,
  # telemetry, and the ship-log narration.
  smoke_error = nil
  result = Release::SealRun.call(
    host: PROD_URL,
    error: -> { smoke_error },
    on_retry: ->(delay) { say("  🔁 first smoke attempt failed — waiting #{delay}s for the dyno boot window, retrying once") }
  ) do |_attempt|
    smoke_error = nil # the FINAL attempt's error is the one the summary reports
    begin
      # Routed through the telemetry wrapper WITHOUT changing the seal's semantics:
      # same chdir + capture, and run_test_scope RE-RAISES a raised SystemCallError
      # (bad/missing script path) after emitting its FAILED action, so the rescue
      # below still degrades it to a red seal (never ok=false from Open3 raising).
      out, ok = run_test_scope("prod_smoke_seal", "bin/prod-smoke", APP,
                               capture: true, chdir: repo_path(APP), repo: APP)
    rescue SystemCallError => e
      out, ok, smoke_error = "", false, e.message
    end
    print out unless out.to_s.empty? # each attempt's output prints as it lands
    [out, ok]
  end
  ok      = result.ok
  seal    = result.seal
  summary = seal.summary
  host    = PROD_URL
  smoke_status = ok ? "completed" : "failed"

  # Record the seal on prod (best-effort). conductor() abort!s on a heroku-run
  # failure → SystemExit; the deploy already happened, so a board blip on this
  # write must NOT abort the ship. The verdict + rollback below stand regardless.
  begin
    conductor(
      "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
      "r.record_smoke_seal!(Release::SmokeSeal.from_result(" \
      "passed: #{ok ? 'true' : 'false'}, summary: #{summary.inspect}, checked_at: Time.current)); " \
      "Release::Conductor.record_event!(release: r, step: 'prod_smoke', status: #{smoke_status.inspect}, " \
      "source: 'conductor', message: #{summary.inspect}, idempotency_key: \"\#{r.slug}:prod_smoke:#{smoke_status}\"); " \
      "puts({ sealed: r.smoke_seal&.status }.to_json)"
    )
    say("  seal recorded on #{rel_slug}: #{seal.badge} #{seal.status}")
  rescue SystemExit, StandardError => e
    say("  ⚠ seal not recorded — board write failed (#{e.message}); the verdict below still stands")
  end

  return seal.status if ok

  # RED SEAL — alert + the EXACT rollback. NON-BLOCKING: no abort, no auto-rollback.
  # Release.current is still `assembled` here (step 6 ships it next), so
  # Release#abandon! is still valid.
  say("")
  say("🔴 PRODUCTION SMOKE SEAL FAILED — #{host}")
  say("   The deploy already landed; this is a post-ship SEAL, so the ship is NOT aborted.")
  say("   Roll back ONLY if you decide to (the seal never auto-rolls-back):")
  seal.rollback_commands(repo: APP, heroku_app: APP, deployed_sha: ship_sha[APP]).each { |c| say("     #{c}") }
  say("")
  seal.status
end

# --- ship -------------------------------------------------------------------
def ship
  # RESUMABLE SHIP: `--finalize-only [<release>]` runs ONLY the record+seal+install
  # steps a watcher-process kill skipped, against an already-deployed frozen SHA.
  # It NEVER deploys — it guards that the SHA is genuinely live first, then records.
  # `bin/release finalize <release>` is the same path with its own verb.
  return finalize(Release::Cli.positional_slugs(ARGV).first) if Release::Cli.take_flag(ARGV, "--finalize-only")

  by = opt_value("--by") || ENV["USER"] || "operator"
  @ship_live = [] # the "what's live this run" trail for the partial-ship report
  avi_span = false # set once the Avi deploy-lane activity opens (gates its close)
  g4_gate = nil    # :open once the G4 Ship gate opens; :closed once a verdict lands

  say("Run Deployment#{PROD ? ' (PROD)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Read the active release + its per-repo deploy plan + the QA-frozen SHAs.
  #    If the prior run already promoted the release card but did not finish
  #    member flips, resume that shipped release by slug. A READ (read_only:) so
  #    a dry-run previews the real plan without mutating.
  step("record (read-only): release + repo_plan + qa_shas")
  result = conductor(
    "r = Release.current || Release.last_shipped; " \
    "unfinished = r ? r.tasks.where.not(stage: 'shipped').count : 0; " \
    "abort('no active release to ship') unless r && (r.active? || unfinished.positive?); " \
    "puts({slug: r.slug, state: r.state, branch: r.branch, " \
    "resuming_member_ship: (!r.active? && unfinished.positive?), unfinished_members: unfinished, " \
    "repos: Release::Conductor.repo_plan(r), qa_shas: (r.metadata['qa_shas'] || {}), " \
    "qa_gates: (r.metadata['qa_gates'] || {})}.to_json)",
    read_only: true
  )
  abort!("no active release to ship") if result["slug"].to_s.empty?
  rel_slug = result["slug"]
  state    = result["state"]
  repos    = result["repos"] || []
  qa_shas  = result["qa_shas"] || {}
  # What the G3 pre-QA gate CERTIFIED this run (repo => {sha, cmd, ok}) — the only
  # grounds on which G4 may skip its own suite. See Release::ShipSequence.
  qa_gates = result["qa_gates"] || {}
  resuming_member_ship = !!result["resuming_member_ship"]
  # Don't ship a candidate that hasn't been assembled + QA'd (the model would
  # otherwise allow assembling→shipped, bypassing the QA gate). The only
  # exception is retrying the final member flips for a release already marked
  # shipped by a prior production deploy record step.
  if !DRY && state != "assembled" && !resuming_member_ship
    abort!("release is '#{state}', not assembled — `bin/release prepare` + QA it first")
  end

  gem_groups = repos.select { |g| g["kind"] == "gem" } # already producer-first
  app_groups = Release::ShipSequence.ordered_app_groups(repos.select { |g| g["kind"] == "app" }) # hub first
  say("  shipping #{rel_slug} (#{state}): #{gem_groups.size} gem(s) → hub → #{[app_groups.size - 1, 0].max} satellite(s)")
  say("  resuming final member flips: #{result['unfinished_members']} unfinished") if resuming_member_ship
  say("  partial-ship: abort on first failure; re-run resumes (gems skip, ref pushes no-op, re-pins idempotent)")

  # The QA-frozen SHA to ship per repo (advanced by a re-pin commit in step 4).
  # Resolved BEFORE the preflight, which pins each app's ship workspace at it.
  ship_sha = {}
  repos.each { |g| ship_sha[g["repo"]] = frozen_sha_for(g["repo"], qa_shas) }

  # PREFLIGHT — before ANYTHING is published, pushed, or deployed: materialize the
  # ship workspaces at the frozen SHA (so an env failure aborts while the release is
  # still fully recoverable) and refuse a gem repo whose primary would publish
  # uncommitted tracked changes. A dirty APP primary is now only a note — the deploy
  # does not read it.
  ship_preflight(app_groups, gem_groups, ship_sha)

  # 2. "What's already live" pre-flight, then Avi's ship gate, then explicit
  #    ship authority — turf included (its bin/deploy keeps its own smoke + rollback).
  whats_live(repos, qa_shas)

  # 2a. Avi's ship gate (§1.2): run the FULL local suite (registry test_cmd) on
  #     the FROZEN ship SHA — the exact prod code — BEFORE ship authority, so
  #     "shipped" can never mean "untested". A red gate scoped-aborts here,
  #     before the confirm and before any push, leaving origin untouched.
  #     (Browser-level verification is the post-deploy prod smoke SEAL — the old
  #     "full e2e" wording here overstated what test_cmd runs.)
  #
  #     G4 SHIP opens HERE, spanning the frozen-SHA gate, the prod deploys,
  #     /up smokes, post-deploy hooks, and the smoke seal; the ship_gate
  #     ReleaseEvents STAY (they light the pizza tracker's stage stamps — gates
  #     record verdicts, never replace stamps). Closed success after the seal
  #     records, failed by the SystemExit wrapper below on any abort.
  record_release_event(rel_slug, "ship_gate", "started", actor: by)
  record_gate_open(rel_slug, "g4_ship", actor: by)
  g4_gate = :open
  avi_ship_gate(app_groups, ship_sha, qa_gates)
  record_release_event(rel_slug, "ship_gate", "completed", actor: by)

  # 2b. The ship-authority gate — explicit, AFTER Avi's test confirmation and
  #     BEFORE any deploy. confirm() honors --yes (hands-off) + --dry-run (previews).
  step("ship authority: Avi's ship gate passed on the frozen SHA — confirming production deploy")
  record_release_event(rel_slug, "ship_authorized", "started", actor: by)
  abort!("aborted — production deploy not confirmed") unless confirm("Deploy this release to production?")
  record_release_event(rel_slug, "ship_authorized", "completed", actor: by)

  # Deploy-lane narration: the ship is authorized — Avi is shipping to prod. Open a
  # role activity (best-effort) so the heartbeat attributes the deploy to him, matching
  # the board's Avi→shipped intent recorded just below. Opened AFTER ship authority
  # so a declined ship never shows Avi shipping.
  open_role_span("avi", "ship → prod")
  avi_span = true

  # 2c. The ship is now authorized + proceeding — record the Avi → shipped intent for
  #     every member so /deployments shows him shipping LIVE (a green ticking timer)
  #     through the deploy, instead of an empty dashed ship slot until `ship!` lands
  #     (the 2026-06-25 unfilled-ship-slot incident). Recorded AFTER ship authority
  #     so a declined ship never shows Avi shipping. Append-only + idempotent
  #     (record_intent_event reuses the open intent; `ship!` supersedes it). On a
  #     partial-ship abort the intent stays open — correct (Avi is still shipping) and
  #     a re-run reuses it. A board WRITE → suppressed in --dry-run. BEST-EFFORT
  #     (record_deploy_intent): a transient prod-board failure on this cosmetic ship-slot
  #     write must never abort the production deploy — it warns and continues.
  step("record: Avi shipped intent (live crew ticker)")
  record_deploy_intent(
    "Avi shipped intent",
    "r = Release.current; n = Release::Conductor.record_deploy_intents!(r, to_stage: 'shipped', actor: 'avi'); " \
    "puts({ intent: 'shipped', actor: 'avi', members: n.size }.to_json)"
  )
  record_release_event(rel_slug, "deploy_prod", "started", actor: by)

  # 3. Gems FIRST (producer-first): publish (skip-if-live; yank safety = `gem push`
  #    fails closed on a yanked number) + ff. On the happy path prepare already
  #    published every gem member BEFORE QA (publish_gems_for_qa), so this is the
  #    idempotent VERIFY — and the backstop for a release prepared before that.
  published_gems = {} # repo => version — every gem now live; consumers re-pin to these
  gem_groups.each do |group|
    repo    = group["repo"]
    version = gem_version_for(repo, group, ship_sha[repo])
    ship_gem(repo, version, ship_sha[repo], Array(group["members"]).map { |m| m["slug"] })
    published_gems[repo] = version
  end

  # 4. Auto-re-pin consumers (after ALL gems live, before any app deploy).
  repin_consumers(app_groups, published_gems, ship_sha)

  # 5. Apps hub-first, then satellites: test gate → prod adapter.
  app_groups.each { |group| deploy_app(group, ship_sha[group["repo"]]) }

  # 5b. Post-deploy hooks on PROD — after every app deployed + smoked, run each
  #     member's declared post_deploy_cmd against its PRODUCTION app, record the
  #     [post-deploy] outcome, and ABORT ship on a non-zero exit. Aborting here (a
  #     post-deploy failure) lands BEFORE the ship! record (step 6), so the release
  #     stays `assembled` (recoverable) and a re-run resumes (the command is
  #     idempotent). dry-run prints the plan.
  run_post_deploy(repos, target: :prod)

  # 5c. Post-ship production smoke SEAL — run the read-only @qa-readonly suite
  #     against PROD and record a 🟢/🔴 seal on the release. NON-BLOCKING (a red
  #     seal alerts + prints the rollback but never aborts the ship). BEFORE step 6
  #     so post_release_notes reads the SAME verdict. See production_smoke_seal.
  seal_status = production_smoke_seal(app_groups, ship_sha, rel_slug)

  # G4 verdict: every repo deployed, /up green, post-deploy hooks green — the
  # gate PASSED. The seal is G4's non-blocking closing beat: its result already
  # rides the sops (run_test_scope collector) and lands in metadata.seal here,
  # but a red seal does NOT flip success (the deploy landed; the operator stays
  # the gate on rollback, exactly as the seal never aborts the ship).
  record_gate_close(rel_slug, "g4_ship", true, metadata: seal_status ? { "seal" => seal_status } : {})
  g4_gate = :closed

  # 6. Record LAST — only after EVERY repo deployed. Stamp the hub's shipped SHA,
  #    promote the release card to Last Release immediately, then flip member
  #    tasks to `shipped` one second apart so live viewers see the deployment land
  #    before the task cards walk across the board. Address the release by slug:
  #    Release.current becomes nil as soon as the release is marked shipped.
  deployed_sha = ship_sha[APP].to_s
  # Fallback: read the ref the ship ACTUALLY advanced (origin/main), never the
  # primary checkout's HEAD. The ship no longer moves the primary's local branch, so
  # its HEAD may sit on a feature branch or a stale main — recording that as the
  # deployed SHA would put a commit on the release card that never went to prod.
  deployed_sha = git_capture("-C", repo_path(APP), "rev-parse", "origin/main").first.strip if deployed_sha.empty? && !DRY
  # Best-effort per-member usage for the assembled→shipped flips, captured from
  # the conductor's LOCAL transcript (the flips run on prod, transcript-less).
  ship_usage = move_usage_map(repos.flat_map { |g| Array(g["members"]).map { |m| m["slug"] } }.compact.uniq)
  step("record: Release::Conductor.ship! + post_release_notes")
  shipped = conductor(
    "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
    "Release::Conductor.ship!(release: r, deployed_sha: #{deployed_sha.inspect}, by: #{by.inspect}, production_url: #{PROD_URL.inspect}, usage_by_slug: #{ship_usage.inspect}, member_pause: 1); " \
    "Release::DurationCache.refresh_recent!(limit: 3); " \
    "notes = Release::Conductor.post_release_notes(release: r); " \
    "puts({slug: r.slug, state: r.reload.state, sha: r.deployed_sha.to_s[0,7], notes_delivered: notes[:delivered]}.to_json)"
  )

  say("")
  say("🚀 Shipped #{rel_slug} → production#{DRY ? ' (DRY RUN — nothing executed)' : " (#{short(deployed_sha)})"}.")
  say("  release notes: #{shipped['notes_delivered'] ? 'posted' : 'not delivered (webhook unset?)'}") unless DRY

  # 7. Restore each app's PRIMARY checkout to a clean `main`, now fast-forwarded to
  #    what shipped — the COMPLEMENT of ship_preflight's ADVISORY. The ship itself
  #    never touches these trees any more, so this is pure courtesy for the next
  #    session (a review/QA cycle can leave a primary on a leftover branch, and the
  #    next session would otherwise integrate from the wrong floor —
  #    retro-rel-20260623 line 54). Best-effort + non-fatal: the ship has already
  #    succeeded, and a primary carrying uncommitted/unpushed work is REFUSED and
  #    left exactly as its owner left it.
  restore_primaries(app_groups)

  # 7b. Sync the installed agent docs from the tree that just shipped — the OWNED
  #     pipeline run of bin/install-agent-docs (task name-install-agent-docs-owner).
  #     It must be POST-SHIP, not post-merge: the installer syncs from its own root,
  #     and only the hub's SHIP WORKSPACE (pinned at the shipped SHA) is guaranteed
  #     to hold exactly what shipped — the primary may be a release behind, or busy
  #     with a live session's work (a qa-release-time prepare run would install
  #     main's STALE docs and leave the drift in place). See sync_agent_docs.
  sync_agent_docs
  close_role_span("shipped #{rel_slug} → prod")
rescue SystemExit => e
  # G4 close-fail wrapper: an abort inside the gate window (a red frozen-SHA
  # gate, a failed deploy//up smoke, a post-deploy hook failure) IS the gate
  # failing — close the attempt `failed` with the collected SOPs. Best-effort
  # (record_gate_close can never raise) and the abort ALWAYS proceeds below
  # (raise in dry-run, exit(status) otherwise) — the close never masks it.
  record_gate_close(rel_slug, "g4_ship", false, metadata: { "aborted" => true }) if g4_gate == :open
  # Close the Avi activity on a partial-ship abort too (best-effort) so the
  # heartbeat activity resolves instead of hanging open. Gated by avi_span so an
  # abort BEFORE the activity opened (e.g. no active release) never emits a stray
  # `end`.
  close_role_span("ship aborted partway") if avi_span
  # Partial-ship recovery: abort! (Kernel#abort) raised SystemExit mid-train. The
  # abort message already printed; add what's live + the idempotent re-run path.
  raise if DRY # a dry-run abort (e.g. no active release) surfaces as-is

  if @ship_live&.any?
    warn("")
    warn("✗ Ship ABORTED partway — the release record is recoverable; re-run finishes unfinished deploy/member steps.")
    warn("  Already live this run:")
    @ship_live.each { |line| warn("    ✓ #{line}") }
    warn("  Re-run `bin/release ship` to resume: published gems skip, fast-forwards no-op, re-pins are idempotent.")
  end
  exit(e.respond_to?(:status) && e.status ? e.status : 1)
end

# --- finalize: record the steps a KILLED ship skipped ------------------------
# `bin/release finalize <release>` (also `bin/release ship --finalize-only <release>`).
#
# THE STRAND IT HEALS. The github_actions hub ship WATCHES prod-deploy.yml as a
# long-lived process; GitHub Actions owns the Heroku push + /up smoke INDEPENDENTLY,
# so a harness/OS kill of the watcher (IOError, stream-closed) leaves the deploy
# LANDED but the board at `assembled` — Conductor.ship!, the smoke seal, and
# install-agent-docs never ran. This finishes exactly those steps, IDEMPOTENTLY,
# and REFUSES to run against a SHA that did not actually deploy. It replaces the
# fragile hand-run `heroku run` recovery recipe with one guarded command; the
# deploy mechanics (push_frozen_main, deploy_app) are untouched — this only wraps
# the record+seal+install tail.
#
# It is IDEMPOTENT: the pure Release::ShipSequence.finalize_pending? decides which
# of {seal, ship, notes} still need running from the release's own state, so a
# re-run on an already-finalized release is a clean NO-OP (no double Discord notes,
# no double records). install-agent-docs + primary-restore ride along (idempotent
# file ops) whenever any step is pending.
def finalize(slug = nil)
  by = opt_value("--by") || ENV["USER"] || "operator"
  @ship_live = []
  say("Finalize release (record the steps a killed ship skipped)#{PROD ? ' (PROD)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Resolve the release + its deploy plan + the post-deploy record state. A
  #    READ (read_only:) so a dry-run previews without mutating. Address by the
  #    given slug, else the last shipped/active release (a strand sits at either
  #    `assembled` (nothing recorded) or `shipped` (a partial finalize)).
  slug = slug.to_s.strip
  slug = opt_value("--slug").to_s.strip if slug.empty?
  step("record (read-only): release + repo_plan + qa_shas + finalize state")
  lookup = slug.empty? ? "Release.current || Release.last_shipped" : "Release.find_by(slug: #{slug.inspect})"
  result = conductor(
    "r = #{lookup}; " \
    "abort('no release to finalize' + (#{slug.inspect}.empty? ? '' : \" for slug #{slug}\")) unless r; " \
    "puts({slug: r.slug, state: r.state, sealed: r.smoke_sealed?, " \
    "notes_completed: r.event_completed?('release_notes'), " \
    "members_all_shipped: r.tasks.where.not(stage: 'shipped').empty?, " \
    "repos: Release::Conductor.repo_plan(r), qa_shas: (r.metadata['qa_shas'] || {})}.to_json)",
    read_only: true
  )
  # --dry-run returns {} from a read? No — read_only bypasses the dry gate, so the
  # read runs. But guard the empty case (a --local dry with no DB) defensively.
  abort!("no release to finalize") if result["slug"].to_s.empty?
  rel_slug = result["slug"]
  state    = result["state"]
  repos    = result["repos"] || []
  qa_shas  = result["qa_shas"] || {}
  sealed   = !!result["sealed"]
  notes_completed = !!result["notes_completed"]
  members_all_shipped = result.fetch("members_all_shipped", true)

  # A release must be `assembled` (the strand) or `shipped` (a partial finalize) —
  # never finalize something still in QA (that would mark shipped a release the
  # deploy never even started).
  unless %w[assembled shipped].include?(state)
    abort!("release #{rel_slug} is '#{state}', not assembled/shipped — nothing to finalize (run `bin/release ship` to deploy it first)")
  end

  app_groups = Release::ShipSequence.ordered_app_groups(repos.select { |g| g["kind"] == "app" })
  ship_sha   = {}
  repos.each { |g| ship_sha[g["repo"]] = frozen_sha_for(g["repo"], qa_shas) }

  # 2. GUARD — REFUSE unless the frozen SHA is genuinely LIVE on prod for EVERY app.
  #    finalize records, it never deploys, so it must never mark shipped a release
  #    that did not deploy. deploy_already_live? fails closed on any unreadable /
  #    unconfirmed signal (per strategy — see Release::ShipSequence).
  say("")
  step("finalize guard: prove every app's frozen SHA is already live on prod")
  not_live = app_groups.reject { |g| deploy_already_live?(g, ship_sha[g["repo"]]) }
  if not_live.any?
    names = not_live.map { |g| "#{g['repo']} @ #{short(ship_sha[g['repo']])}" }.join(", ")
    # A DRY preview REPORTS the guard verdict but does not abort (so the plan still
    # prints); a real finalize REFUSES — it records an already-deployed release and
    # must never mark shipped a deploy that did not land.
    abort!("refusing to finalize — NOT confirmed live on prod: #{names}. " \
           "finalize records an already-deployed release; it never deploys. " \
           "If the deploy really did not land, run `bin/release ship` to deploy it.") unless DRY
    say("  ⚠ [dry-run] would REFUSE: NOT confirmed live on prod: #{names}")
  else
    say("  ✓ #{app_groups.size} app(s) confirmed live on prod at the frozen SHA")
  end

  # 3. What did the killed ship skip? (pure, from the release's own state.)
  pending = Release::ShipSequence.finalize_pending?(state: state, sealed: sealed,
                                                    notes_completed: notes_completed,
                                                    members_all_shipped: members_all_shipped)
  say("")
  if pending.empty?
    say("✓ #{rel_slug} is already finalized (state=#{state}, sealed, notes delivered) — nothing to do (clean no-op).")
    return
  end
  say("  pending finalize steps: #{pending.join(', ')}")

  # DRY stops here: the guard verdict + the pending plan are shown, nothing mutated.
  if DRY
    say("")
    say("✓ Finalize plan previewed (DRY RUN — nothing executed). Re-run without --dry-run to record #{pending.join('/')}.")
    return
  end

  abort!("aborted — finalize not confirmed") unless confirm("Finalize #{rel_slug} — record #{pending.join('/')} + install docs?")

  # 4. Run ONLY the skipped steps, in the live-ship order (seal 5c → ship! 6 →
  #    notes 6 → restore/install 7). Each is idempotent; finalize_pending? gates
  #    the two non-idempotent-by-nature ones (notes' Discord delivery; the ship!
  #    member cadence) so a re-run never double-fires.
  seal_status = production_smoke_seal(app_groups, ship_sha, rel_slug) if pending.include?(:seal)

  if pending.include?(:ship)
    deployed_sha = ship_sha[APP].to_s
    deployed_sha = git_capture("-C", repo_path(APP), "rev-parse", "origin/main").first.strip if deployed_sha.empty?
    step("record: Release::Conductor.ship! + DurationCache.refresh_recent!")
    conductor(
      "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
      "Release::Conductor.ship!(release: r, deployed_sha: #{deployed_sha.inspect}, by: #{by.inspect}, production_url: #{PROD_URL.inspect}, usage_by_slug: {}, member_pause: 1); " \
      "Release::DurationCache.refresh_recent!(limit: 3); " \
      "puts({slug: r.slug, state: r.reload.state, sha: r.deployed_sha.to_s[0,7]}.to_json)"
    )
  end

  if pending.include?(:notes)
    step("record: Release::Conductor.post_release_notes")
    notes = conductor(
      "r = Release.find_by!(slug: #{rel_slug.inspect}); " \
      "n = Release::Conductor.post_release_notes(release: r); " \
      "puts({notes_delivered: n[:delivered]}.to_json)"
    )
    say("  release notes: #{notes['notes_delivered'] ? 'posted' : 'not delivered (webhook unset?)'}")
  end

  # 5. The idempotent tail: restore each app primary to a clean `main`, then sync
  #    the installed agent docs from the shipped hub tree (the install-agent-docs
  #    the killed ship skipped). Both best-effort + non-fatal.
  restore_primaries(app_groups)
  sync_agent_docs

  say("")
  say("✓ Finalized #{rel_slug} — recorded #{pending.join(', ')}. The board now reflects the shipped release.")
end

# Return each app's PRIMARY checkout to a clean `main` after a ship — the
# COMPLEMENT of ship_preflight's offender DETECTION (Release::ShipSequence). A
# review/QA cycle can leave a primary on a leftover `pr-NNN` branch, so the next
# session integrates/deploys from the wrong floor (retro-rel-20260623 line 54).
# Shells the same `bin/agent-worktree restore-primary` an operator runs by hand —
# which REFUSES (non-zero) any primary with uncommitted/unpushed work — so this is
# best-effort: a refusal is reported but NEVER fails an already-completed ship.
# No-op under --dry-run (the ship deployed nothing to restore around).
def restore_primaries(app_groups)
  return if DRY

  say("")
  step("restore primaries: return each app checkout to a clean `main` for the next session")
  Array(app_groups).each do |group|
    repo = group["repo"]
    out, status = Open3.capture2e("bin/agent-worktree", "restore-primary", repo)
    print(out)
    say("  ⚠ #{repo}: primary left as-is (uncommitted/unpushed work) — restore by hand") unless status.success?
  end
end

# Post-ship agent-docs sync — the OWNED pipeline step that runs
# bin/install-agent-docs after every prod ship, so adapter/skill/SOP merges stop
# leaving the installed docs (~/.claude + ~/.codex skills, the projects-root
# AGENTS.md/CLAUDE.md) drifted until someone happens to run the installer by hand
# (previously the only owned run was Alex's share-insights act).
#
# It installs from the hub's SHIP WORKSPACE — the tree pinned at the exact SHA that
# just shipped — falling back to the primary if there is no workspace (a ship that
# resolved no hub member). The installer syncs from its own $ROOT, so the tree it
# runs in IS the docs it installs, and the workspace is the only tree GUARANTEED to
# hold what shipped: the ship no longer fast-forwards the primary's local `main`
# (restore_primaries does, best-effort, and it correctly REFUSES a primary carrying
# a live session's work) — so reading the primary could install docs from a `main`
# that is one release behind. Runs unconditionally (idempotent file copies — a ship
# with no docs changes is a cheap no-op that also heals prior drift), and is
# NON-FATAL by construction (rescue-and-warn, like the merged:main stamps): a
# docs sync must never abort or fail an already-completed ship. Under --dry-run,
# `sh` prints the command and skips. Steffon owns this step; the warn line hands
# the by-hand fix to whoever is watching the ship.
def sync_agent_docs
  say("")
  step("sync installed agent docs: bin/install-agent-docs from the shipped hub tree")
  root = Release::GateWorkspace.path(repo_path("mcritchie-studio"), role: "ship")
  root = repo_path("mcritchie-studio") unless File.exist?(File.join(root, "bin", "install-agent-docs"))
  installer = File.join(root, "bin", "install-agent-docs")
  out, ok = sh(installer, capture: true)
  print(out)
  say("  ⚠ agent-docs install failed — run `#{installer}` by hand (the ship already succeeded)") unless ok
rescue StandardError => e
  say("  ⚠ agent-docs install skipped (#{e.message}) — run `bin/install-agent-docs` by hand (the ship already succeeded)")
end

# --- archive (the DevOps loop's conclusion) --------------------------------
# Run the worktree-reclaim batch. PREVIEW (apply: false) runs the reclaim tool's
# OWN dry-run (no --yes) — it only LISTS reclaimable worktrees, mutating nothing —
# so it runs for real even under bin/release --dry-run (a read, like
# conductor(read_only:), it bypasses sh's dry-run gate). With apply: true it adds
# --yes to actually stop each stack, flush its Redis DB, remove the worktree +
# branch, and refresh the registry (reclaims squash-merged legacy worktrees too).
# Streams the tool's output and returns [output, ok?] so the caller can count
# reclaimed worktrees for the summary.
def reclaim_worktrees(apply:)
  cmd = ["bin/agent-worktree", "cleanup", "--reclaim"]
  cmd << "--yes" if apply
  out, status = Open3.capture2e(*cmd)
  print(out)
  [out, status.success?]
end

# Parse the "reclaimed N worktree(s)" summary bin/agent-worktree prints after a
# --reclaim --yes teardown; 0 when nothing was reclaimed / the line is absent.
def reclaimed_count(out)
  out.to_s[/reclaimed (\d+) worktree/, 1].to_i
end

# "Archive completed tasks": the conclusion of the Deploy lane. Archive every
# shipped task that ISN'T carried by the last shipped release (those stay as the
# board's "Last Release"), then reclaim the merged/shipped feature worktrees.
# Idempotent. The PURE rule lives in the unit-tested
# Release::Conductor.archive_completed! / .archivable_completed_slugs; this CLI
# owns the board WRITE + the worktree-reclaim I/O around it.
def archive
  say("Archive completed tasks#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Plan FIRST — a board READ (read_only:, so it runs even in --dry-run): the
  #    shipped tasks that WOULD archive + the last-release members KEPT shipped.
  step("record (read-only): plan archivable shipped tasks")
  plan = conductor(
    "puts({ archivable: Release::Conductor.archivable_completed_slugs, " \
    "kept: (Release.last_shipped&.tasks&.pluck(:slug) || []) }.to_json)",
    read_only: true
  )
  archivable = plan["archivable"] || []
  kept       = plan["kept"] || []

  sample = archivable.first(8).join(", ")
  sample += ", …(+#{archivable.size - 8})" if archivable.size > 8
  say("  #{archivable.size} shipped task(s) to archive#{archivable.empty? ? '' : ": #{sample}"}")
  say("  #{kept.size} last-release member(s) KEPT shipped#{kept.empty? ? '' : ": #{kept.first(8).join(', ')}"}")

  # 2. Worktree-reclaim PREVIEW — the reclaim tool's own dry-run (no --yes): it
  #    only LISTS reclaimable worktrees, mutating nothing, so it runs for real
  #    even under bin/release --dry-run.
  say("")
  step("worktree reclaim preview: bin/agent-worktree cleanup --reclaim")
  reclaim_worktrees(apply: false)

  # 3. --dry-run stops here: the plan + reclaim preview are shown, nothing mutated.
  if DRY
    say("")
    say("✓ Archive plan previewed (DRY RUN — nothing executed). Re-run without --dry-run to archive + reclaim.")
    return
  end

  # 4. ONE confirm authorizes the board write + the worktree teardown (--yes skips).
  abort!("aborted — archive not confirmed") unless confirm("Archive #{archivable.size} shipped tasks + reclaim worktrees?")

  # 5. Archive on the board (shipped → archived). A board WRITE.
  step("record: Release::Conductor.archive_completed!")
  result = conductor(
    "r = Release::Conductor.archive_completed!; " \
    "puts({ archived: r[:archived], kept: r[:kept], count: r[:count] }.to_json)"
  )
  archived_count = result["count"] || (result["archived"] || []).size
  kept_count     = (result["kept"] || kept).size

  # 6. Reclaim the merged/shipped feature worktrees (--yes = real teardown,
  #    squash-merged legacy worktrees included). The board archive already
  #    succeeded, so a reclaim hiccup just means fewer worktrees freed this run.
  say("")
  step("worktree reclaim: bin/agent-worktree cleanup --reclaim --yes")
  reclaim_out, = reclaim_worktrees(apply: true)
  reclaimed = reclaimed_count(reclaim_out)

  # The reclaim appended to the delete-later ledger — commit it to `release` so it
  # rides the next ship instead of becoming ship-preflight dirt (best-effort).
  commit_artifact_to_release(
    "mcritchie-studio",
    File.join(repo_path("mcritchie-studio"), "docs/agents/maintenance/delete-later.md"),
    "ledger: delete-later after archive (#{archived_count} archived, #{reclaimed} reclaimed)"
  )

  # 7. Summary.
  say("")
  say("✓ Archived #{archived_count} tasks; reclaimed #{reclaimed} worktrees; SHIPPED → #{kept_count}")
end

# --- retro -----------------------------------------------------------------
# Where the durable retro doc lands. Defaults next to the other agent audits in
# THIS checkout (so a worktree run writes into the worktree); RETRO_DOCS_DIR
# overrides it (the test points it at a tmpdir). Mirrors Release::Retro::AUDITS_DIR.
def retro_docs_dir
  return File.expand_path(ENV["RETRO_DOCS_DIR"]) if ENV["RETRO_DOCS_DIR"].to_s != ""

  File.expand_path("../docs/agents/audits", __dir__)
end

# Prompt for a repeatable free-text answer: read lines until a blank one, return
# the collected non-blank entries. Used for the interactive judgment questions.
def prompt_list(question)
  say("#{question} (one per line; blank line to finish)")
  items = []
  loop do
    $stdout.print("  - ")
    line = $stdin.gets
    break if line.nil?

    line = line.strip
    break if line.empty?

    items << line
  end
  items
end

# Build the read-only conductor snippet that gathers + renders the retro on the
# board. The retro answers are operator FREE TEXT — they can carry quotes,
# parens, &&, pipes, backticks. Earlier this raw-interpolated `answers.to_json`
# as a \"-escaped string literal into the `rails runner "<code>"` command, but
# `heroku run`'s remote re-quoting EATS that escaping: parens triggered a remote
# `bash: syntax error near unexpected token '('` and even EMPTY answers arrived
# corrupted (`JSON::ParserError ... got 'worked:[],riction:[],ollowups:'`). So
# the payload now rides as a url-safe Base64 blob (alphabet [A-Za-z0-9_-]=, zero
# shell metacharacters) that the remote runner decodes — as quote-free as the
# bare `slug.inspect` literal the other conductor callers already pass safely.
# Pure (no Rails) so it's unit-tested standalone in test/lib/release_cli_test.rb.
def retro_record_ruby(slug, answers)
  answers_b64 = Base64.urlsafe_encode64(answers.to_json)
  "rel = Release::Retro.resolve(#{slug.inspect}); " \
  "answers = JSON.parse(Base64.urlsafe_decode64(#{answers_b64.inspect})); " \
  "puts((rel ? { slug: rel.slug, markdown: Release::Retro.render(Release::Retro.gather(rel), answers: answers) } : {}).to_json)"
end

# The post-ship "review & learn" step. NON-BLOCKING by construction: it only
# READS the board (gather/render via a read_only conductor) and WRITES a doc to
# the local tree — nothing in the pipeline (archive included) depends on it.
def retro
  # Optional positional release-slug (default = current/last-shipped). Guard so a
  # flag isn't mistaken for the slug when retro is run with no slug.
  slug = (ARGV.first && !ARGV.first.start_with?("--")) ? ARGV.shift : nil
  worked    = opt_values("--worked")
  friction  = opt_values("--friction")
  followups = opt_values("--followup")
  file_tasks = Release::Cli.take_flag(ARGV, "--file-tasks")

  say("Release retro#{slug ? " #{slug}" : ' (current/last-shipped)'}#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Gather + render server-side (a pure READ → runs even in --dry-run). The
  #    operator's free-text answers ride as a Base64 blob (see retro_record_ruby)
  #    so quotes/parens/&& survive the `heroku run` round-trip. Returns
  #    { slug, markdown } (or {} when no release resolves).
  interactive = !(ASSUME_YES || DRY)
  if interactive
    say("")
    worked    += prompt_list("What worked well?")
    friction  += prompt_list("What caused friction?")
    followups += prompt_list("Follow-up tasks to file?")
    say("")
  end
  answers = { "worked" => worked, "friction" => friction, "followups" => followups }

  step("record (read-only): gather + render retro for #{slug || 'the current/last-shipped release'}")
  result = conductor(retro_record_ruby(slug, answers), read_only: true)
  resolved = result["slug"].to_s
  abort!("no release to retro (no active release and nothing shipped yet)") if resolved.empty?

  markdown = result["markdown"].to_s
  path = File.join(retro_docs_dir, "retro-#{resolved}.md")

  # 2. Write the durable doc to the LOCAL tree (skipped in --dry-run).
  if DRY
    say("")
    step("would write retro doc: #{path} (#{markdown.lines.size} lines)")
    say("✓ Retro previewed for #{resolved} (DRY RUN — nothing written).")
    return
  end

  require "fileutils"
  FileUtils.mkdir_p(File.dirname(path))
  File.write(path, markdown)
  say("✓ wrote #{path}")

  # Commit the retro doc to `release` so it ships next round instead of becoming
  # ship-preflight dirt (best-effort, non-fatal; see commit_artifact_to_release).
  commit_artifact_to_release("mcritchie-studio", path, "retro: #{resolved}")

  # 3. Optionally file the follow-ups as tasks (gated by --file-tasks). The doc is
  #    already written, so a `bin/task create` hiccup just means fewer tasks filed.
  if file_tasks && followups.any?
    say("")
    step("file #{followups.size} follow-up task(s) via bin/task create")
    task_bin = File.expand_path("../bin/task", __dir__)
    followups.each do |f|
      title = f.split(/\s+/).first(5).join(" ")
      # --no-claim: filing a retro follow-up must not repoint the conductor's
      # active-feature marker (and its live build-claim) onto each fresh task.
      _, ok = sh(task_bin, "create", "--no-claim", "--title", title, "--kind", "chore",
                 "--agent-context", "Retro follow-up from #{resolved}: #{f}", capture: true)
      say("  - #{ok ? '✓' : '✗'} #{title}")
    end
  elsif followups.any?
    say("  (#{followups.size} follow-up(s) recorded in the doc; re-run with --file-tasks to open them as tasks)")
  end

  say("")
  say("✓ Retro for #{resolved} written to #{path}. NON-BLOCKING — `bin/release archive` is unaffected.")
end

# Guarded so the file can be `require`d (helper coverage) without dispatching.
if __FILE__ == $PROGRAM_NAME
  case ARGV.shift
  when "init"    then init
  when "merge"   then merge
  when "prepare"  then prepare
  when "eject"    then eject
  when "ship"     then ship
  when "finalize" then finalize(Release::Cli.positional_slugs(ARGV).first)
  when "status"   then status
  when "archive"  then archive
  when "retro"    then retro
  else
    warn "usage: bin/release {init|merge <task-slug> [<task-slug>...]|prepare|eject <task-slug>|ship [--finalize-only [<release>]]|finalize [<release>]|status|archive|retro} " \
         "[--task SLUG ...] [--slug REL] [--by NAME] [--feedback …] [--clean-only] " \
         "[--worked …] [--friction …] [--followup …] [--file-tasks] [--local] [--dry-run] [--yes]"
    exit 1
  end
end
