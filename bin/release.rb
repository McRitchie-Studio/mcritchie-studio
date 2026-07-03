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
# The integration branch is now PERSISTENT: every repo keeps a single `release`
# branch that feature PRs merge INTO. Membership flips reviewed→assembled AT
# MERGE (`bin/release merge`); `prepare` just deploys `origin/release` to QA;
# `ship` (later) fast-forwards `release` → `main`.
#
# Usage:
#   bin/release init [--dry-run]
#     One-time (idempotent) per repo: create the persistent `release` branch from
#     `origin/main` in every gem + app repo that doesn't already have one.
#
#   bin/release merge <task-slug> [<task-slug> ...] [--override] [--prod] [--dry-run]
#     Record one-or-more PR merges INTO `release`: resolve every task's PR in ONE
#     read, `gh pr merge` each UNIQUE PR once (base MUST be `release`), then adopt
#     ALL task slugs in a SINGLE `heroku run` (reviewed→assembled, opening/reopening
#     the candidate). Several task records can intentionally ride one PR.
#     REVIEW-GATE GUARD: before any `gh pr merge`, every requested task must be in
#     the `reviewed` stage — a not-yet-reviewed task ABORTS the whole run (naming
#     which task is in which stage), so an unreviewed PR can't be merged onto
#     `release` by accident. `--override` is the explicit escape hatch: it merges a
#     not-yet-reviewed task anyway AND records a `review_bypassed` event on the task's
#     audit spine (the same spine `bin/task move` writes) — the bypass is never silent.
#     With ≥2 slugs it first prints an overlap planner (colliding files +
#     suggested order + likely rebases; warning-only). The batched adopt runs in
#     an `ensure`, so a PR that merged is recorded even if a later merge aborts.
#
#   bin/release prepare [--task SLUG ...] [--slug rel-YYYY-MM-DD-name] [--prod] [--dry-run]
#     Assemble the active release + deploy it to QA. Keeps each app's `release`
#     branch ahead of main (merge-forward guard), then `bin/qa-server deploy
#     <qa_app> origin/release`. No branch-cut/member-merge here — that happened at
#     PR-merge time. `--task` is operator curation (adopt named tasks first). Once
#     each QA dyno boots, runs any member's `devops.post_deploy_cmd` on its QA app
#     (`heroku run`, records [post-deploy] to checks_run, aborts on non-zero).
#     Ends with the RC assembled — review the QA app(s), then ship.
#
#   bin/release ship [--by NAME] [--prod] [--dry-run]
#     Promotes the assembled RC to production: ff main → release branch, push
#     origin, deploy to Heroku, smoke /up, run any member's post_deploy_cmd on the
#     PROD app (aborts on non-zero), stamp deployed_sha + flip to shipped.
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
require_relative "../app/models/release/artifact_commit"
require_relative "../app/models/release/cli"
# CleanCheck is the pure verdict behind the `Deploy with Task` clean-release GUARD
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
# Deploy-side usage capture: read the conductor's LOCAL session transcript and
# diff it against the per-(session, slug) baseline (shared verbatim with bin/task
# + bin/reviewer-select) so reviewed→assembled / assembled→shipped flips carry
# the model/token/cost the agent actually burned. Plain Ruby (no Rails).
require_relative "../lib/agent_session_usage"
require_relative "../lib/task_usage_baseline"

APP = "mcritchie-studio"
HEROKU_REMOTE = "heroku"

# The self-narration CLI this deploy lane opens+closes role spans through (see
# narrate_span). Same bin the session narrates with — which the capture hook DROPS
# from raw actions, so only the resulting SPAN shows on the heartbeat.
ATOMIC_EVENT = File.expand_path("atomic-event", __dir__)

# The persistent per-repo integration branch (same name in every repo). Mirrors
# Release::BRANCH on the record side — feature PRs merge into it, QA deploys from
# it, ship fast-forwards it into main.
RELEASE_BRANCH = "release"

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

def abort!(msg) = abort("✗ #{msg}")
def say(msg) = puts(msg)
def step(msg) = puts("→ #{msg}")

# Loud banner printed at the top of prepare/ship when --local opted out of the
# production board. The local db is stale, so a release run against it won't
# reflect production — only useful for dev/testing.
def warn_local!
  return if PROD

  say("⚠ --local: record ops run against the STALE local DB — the board won't reflect production; use the default for real releases.")
end

# Run a shell command. In dry-run, print it and skip. `chdir:` runs it in
# another directory (used for gem-repo builds/tags). Returns [stdout, ok?].
def sh(*cmd, capture: false, chdir: nil)
  printable = "#{chdir ? "(cd #{chdir}) " : ''}#{cmd.join(' ')}"
  if DRY
    puts "  [dry-run] #{printable}"
    return ["", true]
  end
  opts = chdir ? { chdir: chdir } : {}
  if capture
    out, status = Open3.capture2e(*cmd, opts)
    [out, status.success?]
  else
    ok = system(*cmd, opts)
    ["", ok]
  end
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
  %w[CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID].each do |key|
    value = ENV[key].to_s.strip
    return [value, key == "CODEX_THREAD_ID" ? "codex" : "claude"] unless value.empty?
  end
  [nil, "claude"]
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
# Open+close an AtomicEvent SPAN around a release phase, stamped with the ROLE
# soul the board already attributes that phase to — Steffon assembles (prepare),
# Avi ships — so the heartbeat's deploy spans match the board's stage timeline.
# Narrated through bin/atomic-event (the SAME path the session narrates with,
# which the capture hook DROPS from raw actions, so only the resulting span
# shows). BEST-EFFORT + NON-FATAL: telemetry must never break a release, so a
# missing bin, a down endpoint, or any error is swallowed. Skipped under
# --dry-run (a preview narrates nothing) and when no conductor session is
# resolvable (nothing to attribute the span to).

# Fire one bin/atomic-event subcommand, best-effort. atomic-event itself always
# exits 0; we still swallow everything and redirect its stdout/stderr so the
# narration never disturbs the release log or aborts the run.
def atomic_event(*args)
  return if DRY
  return unless conductor_session_id # no session → nothing to narrate

  system(ATOMIC_EVENT, *args, out: File::NULL, err: File::NULL)
rescue StandardError
  nil
end

def open_role_span(agent, reason)
  atomic_event("start", "--category", "Remote", "--reason", reason, "--agent", agent)
end

def close_role_span(outcome)
  atomic_event("end", "--outcome", outcome)
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
  dir = ENV["TASK_USAGE_DIR"].to_s.strip
  dir.empty? ? File.join(projects_root, ".agents", "task-usage") : dir
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
    out, ok = sh(*heroku_argv, capture: true)
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
    _, ok = sh(rc, "--build", chdir: path)
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
# Record one-or-more PR merges INTO the persistent `release` branch. For each
# task: resolve its PR, verify its base is `release`, `gh pr merge` it; then adopt
# ALL the merged tasks onto the active release in ONE `heroku run` (reviewed→
# assembled). This is the conductor's membership-at-merge command — conflicts
# surface here (at PR-merge), not in prepare.
#
# BATCHED (the per-PR cold-start fix): the OLD merge did a `gh pr merge` + a
# cold-start `heroku run` adopt PER PR; 3 in a loop blew the 2-min tool timeout
# and a mid-run timeout left a PR merged but its task stuck `reviewed`. Now the
# resolve is ONE read and the adopts are ONE write (single dyno spin-up, N flips),
# and the adopt runs in an `ensure` so any PR that merged is recorded even if a
# later step aborts — the half-state can't recur. Single-slug stays identical.

# The one-shot read snippet that resolves EVERY merge slug's PR AND runs the
# review-gate screen in a SINGLE conductor call (one heroku-run spin-up for the
# whole batch). Pure string builder (slugs are alnum/hyphen, safe under .inspect —
# same as the existing single-slug `slug.inspect` literals; `override` is a bare
# bool literal). The screen is a PURE read (Release::Conductor.screen_merge writes
# nothing), so it's safe inside this read-only resolve and previews under --dry-run.
# Emits ONE JSON line:
#   { "tasks": [ { slug, pr_url, repo, stage } | { slug, missing: true } ],
#     "screen": { rows:[…], blocked:[…], overridden:[…], missing:[…], proceed: } }
def batch_resolve_ruby(slugs, override: false)
  "slugs = #{slugs.inspect}; " \
  "rows = slugs.map { |s| t = Task.find_by(slug: s); " \
  "t ? { slug: t.slug, pr_url: t.devops_url('pr').to_s, repo: t.release_repo.to_s, stage: t.stage } " \
  ": { slug: s, missing: true } }; " \
  "screen = Release::Conductor.screen_merge(slugs, override: #{override ? 'true' : 'false'}); " \
  "puts({ tasks: rows, screen: screen }.to_json)"
end

# The one-shot write snippet that adopts EVERY merged slug in a SINGLE `heroku
# run` — N reviewed→assembled flips on one dyno, instead of a cold `heroku run`
# per PR. adopt! is idempotent/self-healing (see Release::Conductor), so a re-run
# is safe. `override` threads the audited review-gate bypass through to adopt! —
# harmless for already-`reviewed` members (records no skip), and for an unreviewed
# member it both attaches it AND stamps the `review_bypassed` audit event.
# `usage_map` ({ slug => {model, tokens_in, tokens_out, cost} }, captured locally
# by move_usage_map) rides each flip's assembled TaskEvent via adopt!(usage:); a
# slug absent from the map records the deterministic spine only.
# Emits ONE JSON line: { "adopted": [...], "slug": <last release>, "state" }.
def batch_adopt_ruby(slugs, usage_map = {}, override: false)
  "slugs = #{slugs.inspect}; " \
  "usage = #{usage_map.inspect}; " \
  "results = slugs.map { |s| r = Release::Conductor.adopt!(Task.find_by!(slug: s), override: #{override ? 'true' : 'false'}, usage: usage[s]); " \
  "{ task: s, release: r.slug, state: r.state } }; " \
  "last = results.last; " \
  "puts({ adopted: results, slug: (last && last[:release]), state: (last && last[:state]) }.to_json)"
end

# A PR's changed-file paths (read-only; goes straight to Open3 so it runs even in
# --dry-run, like git_capture / conductor read_only). [] when gh fails / none.
def gh_pr_files(pr_url)
  out, status = Open3.capture2e("gh", "pr", "view", pr_url, "--json", "files", "-q", ".files[].path")
  return [] unless status.success?

  out.lines.map(&:strip).reject(&:empty?)
end

# Overlap planner (WARNING ONLY — never blocks): before merging a batch, fetch
# each PR's changed files and print the pairwise file collisions, a suggested
# (smallest-footprint-first) merge order, and which PRs will likely need a
# post-merge rebase (they share a file with an earlier-merged same-repo PR). Born
# from real rework: siblings that all touched task.rb/docs/a shared helper passed
# review independently, then conflicted on `release`. The pure decision lives in
# Release::MergePlan; this owns only the gh I/O + printing. A single PR has
# nothing to compare, so it's skipped.
def merge_overlap_report(infos)
  return if infos.size < 2

  say("")
  step("overlap planner: #{infos.size} PRs — fetching changed files (gh pr view)")
  prs = infos.map do |info|
    { "slug" => info["slug"], "repo" => info["repo"], "files" => gh_pr_files(info["pr_url"]) }
  end
  plan = Release::MergePlan.compute(prs)

  if plan["overlaps"].empty?
    say("  ✓ no overlapping files across the batch — merges are independent")
    return
  end

  plan["overlaps"].each do |o|
    files = o["files"].first(8).join(", ")
    more  = o["files"].size > 8 ? " (+#{o['files'].size - 8} more)" : ""
    say("  ⚠ #{o['a']} ∩ #{o['b']} → #{files}#{more}")
  end
  say("  suggested merge order (smallest-footprint first): #{plan['suggested_order'].join(', ')}")
  if plan["rebase"].any?
    say("  post-merge rebase likely (shares files with an earlier-merged PR): #{plan['rebase'].join(', ')}")
  end
  say("  (warning only — `bin/release merge` proceeds in the order given)")
end

# Multiple task-board records can legitimately point at the same PR. Merge/check
# each PR once, then adopt every associated task slug after that PR lands.
def merge_pr_groups(infos)
  Array(infos).group_by { |info| info["pr_url"].to_s }.map do |pr_url, group|
    slugs = group.map { |info| info["slug"].to_s }.reject(&:empty?)
    first = group.first || {}
    first.merge(
      "slug" => merge_pr_group_label(slugs),
      "slugs" => slugs,
      "pr_url" => pr_url
    )
  end
end

def merge_pr_group_label(slugs)
  list = Array(slugs)
  return "" if list.empty?
  return list.first if list.one?

  "#{list.first} (+#{list.size - 1} #{list.size == 2 ? 'task' : 'tasks'})"
end

# Review-gate guard for `bin/release merge`. The DECISION (which slugs are
# blocked vs overridden) is Release::Conductor.screen_merge's — this only renders
# it: it ABORTS the whole run when any requested task isn't `reviewed` (and no
# --override), naming exactly which task is in which stage and how to override; or
# prints a loud OVERRIDE banner for the bypassed tasks (whose skip adopt! records
# on the audit spine). A `nil`/empty screen (e.g. a stub-less dry preview) is a
# no-op. Both lists carry the offending task's actual stage, pulled from screen
# rows, so the operator sees "task X is in stage Y" without re-reading the board.
def enforce_review_gate!(screen)
  rows  = Array(screen["rows"])
  stage = ->(slug) { (rows.find { |r| r["slug"] == slug } || {})["stage"] || "unknown" }

  blocked = Array(screen["blocked"])
  if blocked.any?
    named = blocked.map { |slug| "#{slug} (#{stage.call(slug)})" }.join(", ")
    abort!("review gate: #{named} #{blocked.size == 1 ? 'is' : 'are'} not `reviewed` — " \
           "get the PR(s) through review first, or pass --override to merge anyway " \
           "(the skip is recorded as a `review_bypassed` audit event).")
  end

  overridden = Array(screen["overridden"])
  return if overridden.empty?

  named = overridden.map { |slug| "#{slug} (#{stage.call(slug)})" }.join(", ")
  say("  ⚠ OVERRIDE: merging #{named} past the review gate — recording a `review_bypassed` audit event per task.")
end

def merge
  # `--override` is the audited review-gate escape hatch — consume it BEFORE
  # positional_slugs reads the rest (take_flag deletes it from ARGV so it's never
  # mistaken for a slug).
  override = Release::Cli.take_flag(ARGV, "--override")
  slugs = Release::Cli.positional_slugs(ARGV)
  abort!("usage: bin/release merge <task-slug> [<task-slug> ...] [--override]") if slugs.empty?

  say("Merge #{slugs.join(', ')} into `#{RELEASE_BRANCH}`#{PROD ? ' (PROD board)' : ' (local)'}#{override ? ' (OVERRIDE)' : ''}#{DRY ? ' — DRY RUN' : ''}")

  # 1. Resolve ALL the tasks' PRs AND run the review-gate screen in ONE read (one
  #    heroku-run spin-up for the whole batch; a read — runs even in dry-run).
  step("record (read-only): resolve #{slugs.size} task PR(s)")
  resolved = conductor(batch_resolve_ruby(slugs, override: override), read_only: true)
  infos = resolved["tasks"] || []

  missing = infos.select { |i| i["missing"] }.map { |i| i["slug"] }
  abort!("task(s) not found on the board: #{missing.join(', ')}") if missing.any?
  no_pr = infos.select { |i| i["pr_url"].to_s.empty? }.map { |i| i["slug"] }
  abort!("task(s) have no PR url (devops.pr_url) — set it before merging: #{no_pr.join(', ')}") if no_pr.any?
  infos.each { |i| say("  task #{i['slug']} (#{i['stage']}) · #{i['repo']} · #{i['pr_url']}") }

  # 1b. REVIEW-GATE GUARD (the decision lives in Release::Conductor.screen_merge;
  #     this only prints + aborts). Runs BEFORE any `gh pr merge`: a not-yet-
  #     `reviewed` task ABORTS the whole run unless --override is given. With
  #     --override, the offending tasks proceed but the skip is recorded as a
  #     `review_bypassed` audit event when adopt! flips them (step 5).
  enforce_review_gate!(resolved["screen"] || {})

  # 2. Overlap planner (warning only) — BEFORE any merge, so the operator sees the
  #    file collisions + suggested order first.
  pr_groups = merge_pr_groups(infos)
  if pr_groups.size < infos.size
    say("  #{infos.size} task(s) map to #{pr_groups.size} unique PR(s); each PR will be checked and merged once.")
  end
  merge_overlap_report(pr_groups)

  # 3. Verify EVERY PR's base is `release` up front (fail-fast: nothing merged
  #    yet, so a wrong base can't leave a half-merged batch).
  pr_groups.each do |info|
    pr_url = info["pr_url"]
    base, base_ok = sh("gh", "pr", "view", pr_url, "--json", "baseRefName", "-q", ".baseRefName", capture: true)
    base = base.strip
    # Fail CLOSED: if the base can't be read, don't proceed to an unverified merge.
    abort!("could not read the PR base for #{pr_url} (#{info['slug']}; gh pr view failed) — verify it targets `#{RELEASE_BRANCH}`") if !DRY && !base_ok
    if !DRY && base != RELEASE_BRANCH
      abort!("PR #{pr_url} (#{info['slug']}) targets '#{base}', not '#{RELEASE_BRANCH}' — retarget it " \
             "(`gh pr edit #{pr_url} --base #{RELEASE_BRANCH}`), then re-run.")
    end
  end

  # 4. Merge each PR (bases verified). Track which actually merged so the BATCHED
  #    adopt (step 5, in `ensure`) records every merged PR even if a later merge
  #    aborts — closing the "PR merged, task stuck reviewed" half-state for good.
  merged = []
  begin
    pr_groups.each do |info|
      pr_url = info["pr_url"]
      step("gh pr merge #{pr_url} --merge")
      _, ok = sh("gh", "pr", "merge", pr_url, "--merge", capture: false)
      abort!("gh pr merge failed for #{pr_url} (#{info['slug']}) — resolve on GitHub (conflicts/checks), " \
             "then re-run `bin/release merge` for the remaining slug(s).") unless ok || DRY
      merged.concat(info["slugs"])
    end
  ensure
    # 5. BATCHED adopt: ALL merged slugs in ONE `heroku run` (single dyno spin-up,
    #    N flips) — the core fix. In `ensure` so a partial-failure batch still
    #    records the PRs that DID merge. A board WRITE → suppressed in dry-run.
    if merged.any?
      step("record: Release::Conductor.adopt! ×#{merged.size} in ONE run (#{merged.join(', ')})")
      @merge_result = conductor(batch_adopt_ruby(merged, move_usage_map(merged), override: override))
    end
  end

  result = @merge_result || {}
  say("")
  say("✓ Merged #{merged.join(', ')} into `#{RELEASE_BRANCH}`#{DRY ? ' (DRY RUN — nothing executed)' : ''}.")
  say("  release #{result['slug']} (#{result['state']}) — `bin/release prepare` to QA it.") unless DRY || result.empty?
end

# --- prepare ---------------------------------------------------------------
def prepare
  task_slugs = opt_values("--task")
  slug = opt_value("--slug")

  say("Prepare release#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!
  # On the prod default a non-dry prepare fires a REAL `bin/qa-server deploy`, so
  # gate it like `ship` does. confirm returns true under --yes (hands-off) and
  # --dry-run (previews nothing-executed), so both bypass the prompt.
  return unless confirm("Prepare the current release — assemble + deploy origin/#{RELEASE_BRANCH} to QA?")

  # Deploy-lane narration: Steffon assembles the RC + deploys it to QA. Open a role
  # span so the heartbeat attributes this phase to him (matching the board's stage
  # timeline). Best-effort — see the narrate helpers. `steffon_span` gates the close
  # in the rescue so an abort BEFORE this point never emits a stray `end`.
  open_role_span("steffon", "assemble → deploy RC to QA")
  steffon_span = true

  # 1. Record: CURATE the active release (adopt any explicit --task first), then
  #    read the per-REPO deploy plan (producer-first; one group per repo). The
  #    assemble is DEFERRED to step 4 — after wait_for_boot confirms QA is up — so
  #    a slow dyno can't leave the RC flipped `assembled` against an app that
  #    isn't serving (the /up-smoke race). Curation is a board WRITE → suppressed
  #    in --dry-run; the plan READ runs even in dry-run (read_only:) so a dry-run
  #    previews the REAL plan against the current release without mutating
  #    anything. Membership comes from PR merges (`bin/release merge`), not prepare.
  if DRY
    step("record (read-only preview): Release::Conductor.repo_plan(Release.current)")
    record_ruby = "r = Release.current"
  else
    slugs_ruby = task_slugs.empty? ? "[]" : task_slugs.inspect
    step("record: Release::Conductor.curate! (assemble deferred until QA boots)")
    record_ruby = "r = Release::Conductor.curate!(task_slugs: #{slugs_ruby}, slug: #{slug.inspect})"
  end
  result = conductor(
    "#{record_ruby}; " \
    "puts((r ? { slug: r.slug, state: r.state, branch: r.branch, repos: Release::Conductor.repo_plan(r) } : {}).to_json)",
    read_only: DRY
  )

  rel_slug = result["slug"] || slug || "rel-pending"
  repos    = result["repos"] || []
  abort!("no active release to prepare — merge task PR(s) into `#{RELEASE_BRANCH}` (`bin/release merge SLUG`) or pass --task SLUG, then re-run") if repos.empty?

  app_groups = repos.select { |g| g["kind"] == "app" }
  gem_groups = repos.select { |g| g["kind"] == "gem" }
  say("  release #{rel_slug} (#{result['state']}) · #{repos.size} repo(s): #{app_groups.size} app, #{gem_groups.size} gem")
  record_release_event(rel_slug, "assemble_release", "started")

  # 1b. Record the Steffon assembled QA intent for every member so /deployments shows
  #     him QA-ing the RC live the moment prepare starts — the Deploy mirror of
  #     bin/reviewer-select's review intent (no more hand-run `bin/task intent --to
  #     assembled --actor steffon`). In the STANDARD flow the merge already flipped the
  #     member to `assembled`, so record_deploy_intents! routes through
  #     Release::Conductor#record_qa_intent (the QA intent rides toward `shipped` with a
  #     `qa` marker — superseded by the SHIP, not the merge — and the board re-homes it
  #     to the assembled lane). Append-only + idempotent. A board WRITE → suppressed in
  #     --dry-run (conductor prints the plan). BEST-EFFORT (record_deploy_intent): this
  #     cosmetic ticker write must never abort the QA deploy on a transient prod-board
  #     failure — it warns and continues.
  step("record: Steffon assembled QA intent (live crew ticker)")
  record_deploy_intent(
    "Steffon assembled QA intent",
    "r = Release.current; n = Release::Conductor.record_deploy_intents!(r, to_stage: 'assembled', actor: 'steffon'); " \
    "puts({ intent: 'assembled', actor: 'steffon', members: n.size }.to_json)"
  )

  # 2. Per-app: keep the persistent `release` branch ahead of main (merge-forward
  #    guard), then deploy origin/release to that app's QA. The branch is
  #    populated by PR merges, so there's NO branch-cut/member-merge here. Gems
  #    are NOT deployed — they ride the release as a record, published at ship.
  deployed = [] # [{repo, qa_app, qa_url, sha, ok}]
  qa_shas = {}  # { repo => sha } deployed to QA
  qa_smoke_started = false
  record_release_event(rel_slug, "deploy_qa", "started") if app_groups.any?
  repos.each do |group|
    repo    = group["repo"]
    members = group["members"] || []

    if group["kind"] == "gem"
      members.each do |m|
        step("gem member #{m['slug']} (#{repo} #{gem_version_local(repo)}) — rides the release; published at ship, QA'd via its consuming app")
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

    # c. deploy origin/release to the repo's own QA app. qa-server resolves the
    #    ref in the sibling and pushes its SHA — no local checkout/branch-cut.
    step("qa deploy: bin/qa-server deploy #{qa_app} origin/#{RELEASE_BRANCH} --yes")
    _, qa_ok = sh("bin/qa-server", "deploy", qa_app, "origin/#{RELEASE_BRANCH}", "--yes", capture: false)

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
    qa_ok &&= wait_for_boot(qa_url_for(qa_app))

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

  # 3. Record the QA URL + per-repo deployed SHAs on the release (the board's
  #    current-release header links straight to QA; the SHAs give provenance).
  #    WRITES → suppressed in dry-run; recorded BEFORE the deferred assemble
  #    (step 4) but AFTER wait_for_boot, so the board links a booted QA dyno.
  primary = deployed.find { |d| d["repo"] == APP } || deployed.first
  if primary && !primary["qa_url"].empty?
    step("record: qa_url #{primary['qa_url']}")
    conductor("Release::Conductor.record_qa_deploy(release: Release.current, qa_url: #{primary['qa_url'].inspect}); puts({qa_url: #{primary['qa_url'].inspect}}.to_json)")
  end
  unless qa_shas.empty?
    step("record: qa_shas #{qa_shas.map { |r, s| "#{r}@#{s.to_s[0, 7]}" }.join(', ')}")
    conductor("Release::Conductor.record_qa_shas(release: Release.current, shas: #{qa_shas.inspect}); puts({qa_shas: true}.to_json)")
  end

  # 4. ASSEMBLE — deferred to here so it lands only AFTER every QA app booted
  #    (wait_for_boot returned 200) AND every post-deploy hook ran green. A boot
  #    failure leaves the RC `assembling` so a re-run completes once the dyno is up,
  #    instead of stranding a half-up RC flipped `assembled`. WRITE → suppressed in
  #    dry-run.
  boot_failures = deployed.reject { |d| d["ok"] }
  if boot_failures.any?
    say("")
    say("  ⚠ #{boot_failures.size} app(s) never returned /up 200 — leaving the release `assembling`.")
    say("    Re-run `bin/release prepare` once they boot: #{boot_failures.map { |d| d['repo'] }.join(', ')}")
  else
    # 4a. Post-deploy hooks on the booted QA app(s): run each member's declared
    #     post_deploy_cmd against its QA app, record the [post-deploy] outcome, and
    #     ABORT prepare on a non-zero exit (so the RC stays `assembling`, re-run
    #     resumes). dry-run prints the plan; nothing executes.
    run_post_deploy(repos, target: :qa)

    # 4b. Flip assembling→assembled now that QA booted + every post-deploy passed.
    unless DRY
      step("record: Release::Conductor.assemble!(Release.current) (QA booted)")
      conductor("r = Release.current; Release::Conductor.assemble!(r) if r; puts({ state: r&.reload&.state }.to_json)")
    end
  end

  # 5. Per-repo summary of what was assembled + QA'd.
  say("")
  say("✓ Assembled #{rel_slug}#{DRY ? ' (DRY RUN — nothing executed)' : ''}.")
  gem_groups.each do |g|
    g["members"].each { |m| say("  gem #{g['repo']} (#{m['slug']}) — rides the release; published at ship.") }
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
  say("")
  say("  Review the QA app(s) above, then `bin/release ship`.")
  close_role_span("assembled #{rel_slug} → QA")
rescue SystemExit
  # An abort mid-prepare closes the Steffon span with the abort outcome (best-effort)
  # before re-raising, so the heartbeat span resolves instead of hanging open.
  close_role_span("prepare aborted before assemble") if steffon_span
  raise
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

# --- the clean-release GUARD (`Deploy with Task` runs this FIRST) -----------
# `bin/release status` reports whether `release == main` — i.e. whether the only
# thing a `release → main` fast-forward would ship is ONE freshly-merged task, or
# whether OTHER assembled-but-unshipped work is already riding `release`. The
# `Deploy with Task <task>` composition runs `bin/release status --clean-only`
# BEFORE it merges the expedited task; `--clean-only` turns the report into a
# GATE — it exits nonzero (aborting the expedite) on a dirty release, after
# printing the refusal + the `full-cycle` offer. The pure verdict +
# message live in Release::CleanCheck; this owns only the two live reads.
def status
  clean_only = Release::Cli.take_flag(ARGV, "--clean-only")

  say("Release status#{PROD ? ' (PROD board)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Board signal (read-only, runs even in --dry-run): the tasks already
  #    `assembled` (merged into `release`) but not yet `shipped`, plus the current
  #    release for context. A read mutates nothing, so it's safe under --dry-run.
  step("read (read-only): assembled tasks pending ship + Release.current")
  board = conductor(
    "pending = Task.by_stage('assembled').order(:position).map { |t| { slug: t.slug, title: t.title } }; " \
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
  # so `Deploy with Task` refuses instead of dragging the pending work to prod.
  # A --dry-run previews the verdict without aborting (nothing is executed).
  if clean_only && !verdict["clean"] && !DRY
    abort!("release is not clean — `Deploy with Task` refused (ship the whole release with the `full-cycle` launcher)")
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

# Fast-forward a repo's main up to a SHA, LOCALLY (no push). Split from the push
# so an app's test gate can run on a frozen main and a red gate leaves origin
# untouched. Aborts on a failed checkout or a non-fast-forward.
def ff_main_local(repo, sha)
  path = repo_path(repo)
  abort!("repo not found at #{path} — clone it as a sibling at the projects root") unless DRY || Dir.exist?(path)
  if DRY
    step("ff #{repo} main → frozen #{short(sha)}")
    return
  end

  sh("git", "-C", path, "fetch", "origin", "--quiet")
  _, co = sh("git", "-C", path, "checkout", "main", capture: true)
  abort!("could not checkout main in #{repo} (dirty tree / wrong branch?) — clean it, then re-run `bin/release ship`") unless co
  sh("git", "-C", path, "pull", "origin", "main", "--quiet")
  _, ff = sh("git", "-C", path, "merge", "--ff-only", sha, capture: true)
  abort!("#{repo} main can't fast-forward to #{short(sha)} (it diverged) — rebase/re-prepare, then re-run") unless ff
end

def push_origin_main(repo)
  step("push origin main (#{repo})")
  _, ok = sh("git", "-C", repo_path(repo), "push", "origin", "main")
  abort!("could not push origin main in #{repo} (diverged remote?) — resolve, then re-run `bin/release ship`") unless ok || DRY
end

# The conductor's pre-prod test gate: run the registry `test_cmd` at the repo's
# frozen SHA before the irreversible deploy; scoped-abort on red. repo_script
# apps SELF-GATE (their own deploy runs tests) → no test_cmd → skipped.
def test_gate(repo)
  cmd = app_meta_for(repo)["test_cmd"].to_s
  if cmd.empty?
    step("test gate: #{repo} self-gates (no conductor test_cmd; its deploy runs tests) — skip")
    return
  end

  step("test gate: (cd #{repo}) #{cmd}  [frozen SHA · before prod]")
  return if DRY

  _, ok = sh(*cmd.split, chdir: repo_path(repo))
  abort!("test_cmd failed for #{repo} (#{cmd}) — aborting before the irreversible prod deploy; fix + re-run") unless ok
end

# `bundle lock --update <gem>` with a bounded retry/backoff for RubyGems
# propagation lag (a just-pushed version isn't always instantly resolvable).
def bundle_lock(path, gem, attempts: 3)
  delay = 5
  attempts.times do |i|
    step("bundle lock --update #{gem} (cd #{path}) [#{i + 1}/#{attempts}]")
    _, ok = sh("bundle", "lock", "--update", gem, chdir: path)
    return if ok
    break if i == attempts - 1

    say("  bundle lock failed — RubyGems may not have propagated #{gem} yet; retrying in #{delay}s")
    sleep(delay)
    delay *= 2
  end
  abort!("bundle lock --update #{gem} failed in #{path} after #{attempts} tries — re-run `bin/release ship` once RubyGems has propagated")
end

def checkout_branch(repo, branch)
  _, ok = sh("git", "-C", repo_path(repo), "checkout", branch, capture: true)
  abort!("could not checkout #{branch} in #{repo} for re-pin") unless ok
end

# Best-effort: commit a generated doc (a `retro` doc or the `delete-later.md`
# ledger `archive` updates) onto `release` so it stops landing as ship-preflight
# dirt that the conductor has to stash every release. NON-FATAL — any problem
# leaves the doc uncommitted (today's behavior; the preflight stashes it) and never
# aborts retro/archive. The IO seam around the pure Release::ArtifactCommit:
#   - commit ONLY when the doc is the SOLE uncommitted change (never sweep up dirt),
#   - build on origin/release's tip (ff-only) so the push fast-forwards and the NEXT
#     ship ff's main up to it — no main/release divergence,
#   - ALWAYS restore the checkout to `main` (ensure), even on failure.
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

  done = false
  begin
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

  step(done ? "committed #{rel} to #{RELEASE_BRANCH} (ships on the next release)" \
            : "left #{rel} uncommitted (commit/push failed) — commit it via a docs PR")
end

# Publish (or idempotently skip) one gem, then collapse its release → main at the
# frozen SHA. Skip when the version is already LIVE. Yank safety is delegated to
# `gem push` failing closed: a yanked number isn't in the listing → publish_needed?
# is true → we try to push → RubyGems rejects re-pushing it → publish_gem aborts,
# BEFORE any app deploys. Records the gem as live for the partial report.
def ship_gem(repo, version, frozen)
  abort!("could not resolve a version for gem #{repo} — check #{repo}/#{gem_meta_for(repo)['version_file']}") if version.empty? && !DRY

  if DRY
    step("gem #{repo} #{version}: publish to RubyGems from #{short(frozen)} " \
         "(skip if already live) → tag v#{version} → ff #{repo} main → #{short(frozen)}")
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
  ff_main_local(repo, frozen)
  push_origin_main(repo)
end

# Auto-re-pin (D1): after ALL gems are live, before any app deploys, re-pin each
# consumer's branch-ref'd gem line to the published `~> x.y` so prod builds
# against the release, not a branch. Idempotent (already-pinned → no-op). One
# pass per consumer; the re-pin commit ships on TOP of the frozen SHA (so only
# frozen + the mechanical re-pin reach prod — guarded against un-QA'd drift).
def repin_consumers(app_groups, published_gems, ship_sha)
  return if published_gems.empty?

  gem_names = published_gems.keys
  step("auto-repin consumers of #{gem_names.join(', ')} → ~> x.y (after all gems live, before any deploy)")
  app_groups.each do |group|
    repo = group["repo"]
    path = repo_path(repo)

    if DRY
      step("  #{repo}: re-pin any branch-ref'd published gem in Gemfile → bundle lock --update → " \
           "commit + push origin #{RELEASE_BRANCH} (idempotent; no-op if already pinned)")
      next
    end

    gemfile = File.join(path, "Gemfile")
    next unless File.exist?(gemfile)

    text    = File.read(gemfile)
    pending = Release::ShipSequence.gems_to_repin(gem_names, text)
    if pending.empty?
      say("  #{repo}: Gemfile already pinned for #{gem_names.join(', ')} — no re-pin")
      next
    end

    # The re-pin must build on the QA-frozen SHA. Fetch first so the origin check
    # reads the TRUE remote (not a stale local origin/release ref), then require
    # origin/release == frozen so a post-prepare merge to origin can't sneak out
    # un-QA'd under cover of the re-pin.
    _, fetched = sh("git", "-C", path, "fetch", "origin", "--quiet")
    abort!("could not fetch origin in #{repo} for re-pin — check the remote, then re-run `bin/release ship`") unless fetched

    head, ok = git_capture("-C", path, "rev-parse", "origin/#{RELEASE_BRANCH}")
    abort!("could not read origin/#{RELEASE_BRANCH} in #{repo} for re-pin") unless ok
    if head.strip != ship_sha[repo]
      abort!("#{repo} origin/#{RELEASE_BRANCH} (#{short(head.strip)}) drifted past the QA-frozen SHA " \
             "(#{short(ship_sha[repo])}) — re-run `bin/release prepare` to re-QA before re-pinning")
    end

    checkout_branch(repo, RELEASE_BRANCH)

    # The LOCAL release HEAD must ALSO equal the frozen SHA — origin matching isn't
    # enough. An un-pushed local commit on a dirty sibling would otherwise ride out
    # on the re-pin's ff-push, un-QA'd. (origin/release == frozen already passed, so
    # a mismatch here means a local-only commit.)
    local_head, local_ok = git_capture("-C", path, "rev-parse", "HEAD")
    abort!("could not read local #{RELEASE_BRANCH} HEAD in #{repo} for re-pin") unless local_ok
    if local_head.strip != ship_sha[repo]
      abort!("#{repo} local #{RELEASE_BRANCH} (#{short(local_head.strip)}) drifted from the QA'd SHA " \
             "(#{short(ship_sha[repo])}) — re-run `bin/release prepare`")
    end
    pending.each { |gem| text = Release::GemfileRepin.rewrite(text, gem, published_gems[gem]) }
    File.write(gemfile, text)
    pending.each { |gem| bundle_lock(path, gem) }

    pins = pending.map { |gem| "#{gem} #{Release::GemfileRepin.pessimistic_constraint(published_gems[gem])}" }
    sh("git", "-C", path, "add", "Gemfile", "Gemfile.lock")
    _, committed = sh("git", "-C", path, "commit", "-m", "repin #{pins.join(', ')}", capture: true)
    abort!("could not commit the re-pin in #{repo}") unless committed
    _, pushed = sh("git", "-C", path, "push", "origin", RELEASE_BRANCH, capture: true)
    abort!("could not push the re-pin to origin/#{RELEASE_BRANCH} in #{repo}") unless pushed

    new_head, = git_capture("-C", path, "rev-parse", "HEAD")
    ship_sha[repo] = new_head.strip # ship the re-pin commit (frozen + re-pin)
    @ship_live << "re-pinned #{pins.join(', ')} in #{repo}"
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
      frozen        = qa_shas[repo].to_s
      main_sha, ok  = git_capture("-C", repo_path(repo), "rev-parse", "main")
      at            = ok && !frozen.empty? && main_sha.strip == frozen
      say("    app #{repo}: main #{at ? "already at #{short(frozen)}" : "will ff → #{short(frozen)}"}")
    end
  end
end

# Avi's ship gate: run each app's highest-tier suite (registry `test_cmd`) on the
# FROZEN ship SHA — the exact code that ships — BEFORE the ship-authority gate,
# so approval can never authorize untested code (§1.2 "fixes shipped ≠ tested").
# ff main → frozen LOCALLY (no push) so the suite runs on the frozen tree; a red
# gate scoped-aborts before the confirm, leaving origin untouched. Satellites
# self-gate (their own deploy runs their suite) → no `test_cmd` → skipped.
def avi_ship_gate(app_groups, ship_sha)
  say("")
  step("Avi ship gate: full e2e + highest tier on the FROZEN ship SHA (before ship authority)")
  app_groups.each do |group|
    repo = group["repo"]
    ff_main_local(repo, ship_sha[repo]) # local only — run the suite on the frozen tree
    test_gate(repo)
  end
end

# Deploy one app to prod via its registry adapter. Common prelude: local ff main
# → frozen (the test gate already ran in avi_ship_gate, before ship authority),
# then push origin main. Then the strategy-specific mechanic + smoke policy.
def deploy_app(group, frozen)
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

  ff_main_local(repo, frozen) # local only — a no-op ff (avi_ship_gate already ff'd to frozen)
  push_origin_main(repo)

  case handler
  when :git_push_heroku
    remote = adapter["remote"] || HEROKU_REMOTE
    branch = adapter["branch"] || "main"
    step("deploy: git -C #{repo} push #{remote} #{branch}")
    _, ok = sh("git", "-C", path, "push", remote, branch, capture: false)
    abort!("Heroku deploy failed for #{repo}") unless ok || DRY

    smoke = adapter["smoke_url"].to_s
    if smoke.empty?
      say("  (no smoke_url for #{repo} — smoke skipped)")
    else
      step("smoke: GET #{smoke}/up")
      code, = sh("/usr/bin/curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", "#{smoke}/up", capture: true)
      say("  /up → #{code}") unless DRY
      abort!("smoke failed for #{repo} (#{smoke}/up != 200)") if !DRY && code.strip != "200"
    end
  when :repo_script
    command = adapter["command"].to_s
    args    = Array(adapter["args"])
    abort!("repo_script adapter for #{repo} has no `command`") if command.empty? && !DRY
    step("deploy: (cd #{repo}) #{command} #{args.join(' ')} — repo owns its smoke + rollback")
    _, ok = sh(command, *args, chdir: path)
    abort!("#{repo} deploy script failed (#{command}) — its own rollback applies; fix + re-run `bin/release ship`") unless ok || DRY
  end
  @ship_live << "app #{repo} deployed to production"
end

# --- ship preflight: every app checkout on a clean `main` before any ff -----
# ship ff's each app repo's `main` up to the QA-frozen SHA (avi_ship_gate +
# deploy_app), which assumes the checkout is ON `main` with a CLEAN tree. Twice
# this session a review agent left a checkout on a leftover `pr-NNN` branch / a
# stale uncommitted schema.rb, and the ff broke MID-ship (after gems published +
# ship authority — the worst time). This preflight catches that BEFORE any ff,
# aborting loudly with the offending branch / dirty files. The PURE decision
# (offenders + message) lives in Release::ShipSequence; this owns only the git
# reads. A dry-run prints the plan and runs NO git (so a preview never aborts on a
# legitimately-dirty dev sibling).

# The current branch + dirty-file list for a checkout (live git reads). Split out
# as the I/O seam ship_preflight calls per app repo (stubbed in tests).
def repo_git_state(repo, path)
  branch, = git_capture("-C", path, "rev-parse", "--abbrev-ref", "HEAD")
  status, = git_capture("-C", path, "status", "--porcelain")
  files = status.to_s.lines.map { |l| l[3..].to_s.strip }.reject(&:empty?)
  { "repo" => repo, "branch" => branch.to_s.strip, "dirty" => files.any?, "dirty_files" => files }
end

def ship_preflight(app_groups)
  say("")
  step("ship preflight: each app checkout must be on a clean `main` before any ff")
  if DRY
    app_groups.each { |g| say("  [dry-run] check #{g['repo']} (#{repo_path(g['repo'])}) is on a clean main") }
    return
  end

  states = app_groups.map { |g| repo_git_state(g["repo"], repo_path(g["repo"])) }
  offenders = Release::ShipSequence.preflight_offenders(states)
  abort!(Release::ShipSequence.preflight_message(offenders)) if offenders.any?

  say("  ✓ #{states.size} app checkout(s) on a clean `main`")
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
# SAME verdict (the seal write commits here; step 6 reloads Release.current). The
# WRITE is best-effort: a prod-board blip on the seal record warns + continues —
# the red alert still prints from the LOCAL verdict, independent of the write.
def production_smoke_seal(app_groups, ship_sha, rel_slug)
  step("production smoke seal: bin/prod-smoke #{APP} (@qa-readonly vs prod) — post-ship SEAL, non-blocking")

  # Seal what we DEPLOYED: only when the hub (mcritchie-studio, whose @qa-readonly
  # spec this is) was actually part of this ship. A gem-only / satellite-only ship
  # changes nothing on the hub, so there is nothing to seal.
  unless app_groups.any? { |g| g["repo"] == APP }
    say("  (#{APP} not deployed in this ship — nothing to seal; skipped)")
    return
  end
  unless PROD
    say("  (local ship — the seal smokes the LIVE prod host only; skipped)")
    return
  end
  if DRY
    say("  [dry-run] bin/prod-smoke #{APP} → record 🟢/🔴 seal on Release.current (non-blocking)")
    return
  end

  record_release_event(rel_slug, "prod_smoke", "started")
  out, ok = sh("bin/prod-smoke", APP, capture: true)
  print out unless out.to_s.empty?

  host    = PROD_URL
  summary = ok ? "@qa-readonly green vs #{host}" : "@qa-readonly FAILED vs #{host} — see ship log"
  smoke_status = ok ? "completed" : "failed"
  seal    = Release::SmokeSeal.from_result(passed: ok, summary: summary)

  # Record the seal on prod (best-effort). conductor() abort!s on a heroku-run
  # failure → SystemExit; the deploy already happened, so a board blip on this
  # write must NOT abort the ship. The verdict + rollback below stand regardless.
  begin
    conductor(
      "r = Release.current; abort('no active release to seal') unless r; " \
      "r.record_smoke_seal!(Release::SmokeSeal.from_result(" \
      "passed: #{ok ? 'true' : 'false'}, summary: #{summary.inspect}, checked_at: Time.current)); " \
      "Release::Conductor.record_event!(release: r, step: 'prod_smoke', status: #{smoke_status.inspect}, " \
      "source: 'conductor', message: #{summary.inspect}, idempotency_key: \"\#{r.slug}:prod_smoke:#{smoke_status}\"); " \
      "puts({ sealed: r.smoke_seal&.status }.to_json)"
    )
    say("  seal recorded on Release.current: #{seal.badge} #{seal.status}")
  rescue SystemExit, StandardError => e
    say("  ⚠ seal not recorded — board write failed (#{e.message}); the verdict below still stands")
  end

  return if ok

  # RED SEAL — alert + the EXACT rollback. NON-BLOCKING: no abort, no auto-rollback.
  # Release.current is still `assembled` here (step 6 ships it next), so
  # Release#abandon! is still valid.
  say("")
  say("🔴 PRODUCTION SMOKE SEAL FAILED — #{host}")
  say("   The deploy already landed; this is a post-ship SEAL, so the ship is NOT aborted.")
  say("   Roll back ONLY if you decide to (the seal never auto-rolls-back):")
  seal.rollback_commands(repo: APP, heroku_app: APP, deployed_sha: ship_sha[APP]).each { |c| say("     #{c}") }
  say("")
end

# --- ship -------------------------------------------------------------------
def ship
  by = opt_value("--by") || ENV["USER"] || "operator"
  @ship_live = [] # the "what's live this run" trail for the partial-ship report
  avi_span = false # set once the Avi deploy-lane span opens (gates its close)

  say("Run Deployment#{PROD ? ' (PROD)' : ' (local)'}#{DRY ? ' — DRY RUN' : ''}")
  warn_local!

  # 1. Read the active release + its per-repo deploy plan + the QA-frozen SHAs.
  #    A READ (read_only:) so a dry-run previews the real plan without mutating.
  step("record (read-only): release + repo_plan + qa_shas")
  result = conductor(
    "r = Release.current; abort('no active release to ship') unless r; " \
    "puts({slug: r.slug, state: r.state, branch: r.branch, " \
    "repos: Release::Conductor.repo_plan(r), qa_shas: (r.metadata['qa_shas'] || {})}.to_json)",
    read_only: true
  )
  abort!("no active release to ship") if result["slug"].to_s.empty?
  rel_slug = result["slug"]
  state    = result["state"]
  repos    = result["repos"] || []
  qa_shas  = result["qa_shas"] || {}
  # Don't ship a candidate that hasn't been assembled + QA'd (the model would
  # otherwise allow assembling→shipped, bypassing the QA gate).
  abort!("release is '#{state}', not assembled — `bin/release prepare` + QA it first") if !DRY && state != "assembled"

  gem_groups = repos.select { |g| g["kind"] == "gem" } # already producer-first
  app_groups = Release::ShipSequence.ordered_app_groups(repos.select { |g| g["kind"] == "app" }) # hub first
  say("  shipping #{rel_slug} (#{state}): #{gem_groups.size} gem(s) → hub → #{[app_groups.size - 1, 0].max} satellite(s)")
  say("  partial-ship: abort on first failure; re-run resumes (gems skip, ff no-ops, re-pins idempotent)")

  # PREFLIGHT — BEFORE any ff (avi_ship_gate is the first): assert every app
  # checkout is on a clean `main`. A leftover review branch / dirty schema.rb
  # would otherwise break the ff mid-ship; abort loudly here instead.
  ship_preflight(app_groups)

  # The QA-frozen SHA to ship per repo (advanced by a re-pin commit in step 4).
  ship_sha = {}
  repos.each { |g| ship_sha[g["repo"]] = frozen_sha_for(g["repo"], qa_shas) }

  # 2. "What's already live" pre-flight, then Avi's ship gate, then explicit
  #    ship authority — turf included (its bin/deploy keeps its own smoke + rollback).
  whats_live(repos, qa_shas)

  # 2a. Avi's ship gate (§1.2): run the FULL e2e + highest tier on the FROZEN ship
  #     SHA — the exact prod code — BEFORE ship authority, so "shipped" can
  #     never mean "untested". A red gate scoped-aborts here, before the confirm
  #     and before any push, leaving origin untouched.
  record_release_event(rel_slug, "ship_gate", "started", actor: by)
  avi_ship_gate(app_groups, ship_sha)
  record_release_event(rel_slug, "ship_gate", "completed", actor: by)

  # 2b. The ship-authority gate — explicit, AFTER Avi's test confirmation and
  #     BEFORE any deploy. confirm() honors --yes (hands-off) + --dry-run (previews).
  step("ship authority: Avi's full e2e passed on the frozen SHA — confirming production deploy")
  record_release_event(rel_slug, "ship_authorized", "started", actor: by)
  abort!("aborted — production deploy not confirmed") unless confirm("Deploy this release to production?")
  record_release_event(rel_slug, "ship_authorized", "completed", actor: by)

  # Deploy-lane narration: the ship is authorized — Avi is shipping to prod. Open a
  # role span (best-effort) so the heartbeat attributes the deploy to him, matching
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
  #    fails closed on a yanked number) + ff.
  published_gems = {} # repo => version — every gem now live; consumers re-pin to these
  gem_groups.each do |group|
    repo    = group["repo"]
    version = gem_version_for(repo, group, ship_sha[repo])
    ship_gem(repo, version, ship_sha[repo])
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
  production_smoke_seal(app_groups, ship_sha, rel_slug)

  # 6. Record LAST — only after EVERY repo deployed, so a partial ship leaves the
  #    record `assembled` (recoverable). Stamp the hub's shipped SHA + ship! +
  #    post release notes in one runner call (Release.current is nil post-ship).
  deployed_sha = ship_sha[APP].to_s
  deployed_sha = git_capture("-C", repo_path(APP), "rev-parse", "HEAD").first.strip if deployed_sha.empty? && !DRY
  # Best-effort per-member usage for the assembled→shipped flips, captured from
  # the conductor's LOCAL transcript (the flips run on prod, transcript-less).
  ship_usage = move_usage_map(repos.flat_map { |g| Array(g["members"]).map { |m| m["slug"] } }.compact.uniq)
  step("record: Release::Conductor.ship! + post_release_notes")
  shipped = conductor(
    "r = Release.current; " \
    "Release::Conductor.ship!(release: r, deployed_sha: #{deployed_sha.inspect}, by: #{by.inspect}, production_url: #{PROD_URL.inspect}, usage_by_slug: #{ship_usage.inspect}); " \
    "Release::DurationCache.refresh_recent!(limit: 3); " \
    "notes = Release::Conductor.post_release_notes(release: r); " \
    "puts({slug: r.slug, state: r.reload.state, sha: r.deployed_sha.to_s[0,7], notes_delivered: notes[:delivered]}.to_json)"
  )

  say("")
  say("🚀 Shipped #{rel_slug} → production#{DRY ? ' (DRY RUN — nothing executed)' : " (#{short(deployed_sha)})"}.")
  say("  release notes: #{shipped['notes_delivered'] ? 'posted' : 'not delivered (webhook unset?)'}") unless DRY

  # 7. Restore each app's PRIMARY checkout to a clean `main` — the COMPLEMENT of
  #    ship_preflight's offender DETECTION. A review/QA cycle can leave a primary
  #    on a leftover branch, so the NEXT session would integrate from the wrong
  #    floor (retro-rel-20260623 line 54). Best-effort + non-fatal: the ship has
  #    already succeeded; a primary carrying uncommitted/unpushed work is REFUSED
  #    and left for the operator.
  restore_primaries(app_groups)
  close_role_span("shipped #{rel_slug} → prod")
rescue SystemExit => e
  # Close the Avi span on a partial-ship abort too (best-effort) so the heartbeat
  # span resolves instead of hanging open. Gated by avi_span so an abort BEFORE the
  # span opened (e.g. no active release) never emits a stray `end`.
  close_role_span("ship aborted partway") if avi_span
  # Partial-ship recovery: abort! (Kernel#abort) raised SystemExit mid-train. The
  # abort message already printed; add what's live + the idempotent re-run path.
  raise if DRY # a dry-run abort (e.g. no active release) surfaces as-is

  if @ship_live&.any?
    warn("")
    warn("✗ Ship ABORTED partway — the release is still 'assembled' (recoverable).")
    warn("  Already live this run:")
    @ship_live.each { |line| warn("    ✓ #{line}") }
    warn("  Re-run `bin/release ship` to resume: published gems skip, fast-forwards no-op, re-pins are idempotent.")
  end
  exit(e.respond_to?(:status) && e.status ? e.status : 1)
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
  when "prepare" then prepare
  when "ship"    then ship
  when "status"  then status
  when "archive" then archive
  when "retro"   then retro
  else
    warn "usage: bin/release {init|merge <task-slug> [<task-slug>...]|prepare|ship|status|archive|retro} " \
         "[--task SLUG ...] [--slug REL] [--by NAME] [--clean-only] " \
         "[--worked …] [--friction …] [--followup …] [--file-tasks] [--local] [--dry-run] [--yes]"
    exit 1
  end
end
