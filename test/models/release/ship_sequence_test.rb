require "test_helper"

# Pure decision logic for the multi-repo `bin/release ship`. No git/gem/bundle/
# network here — same IO-free contract as GemfileRepin, so it's trivially unit
# tested and the shell stays thin.
class Release::ShipSequenceTest < ActiveSupport::TestCase
  S = Release::ShipSequence

  # --- strategy_handler: adapter string → handler symbol -------------------

  test "strategy_handler maps git_push_heroku" do
    assert_equal :git_push_heroku, S.strategy_handler("git_push_heroku")
  end

  test "strategy_handler maps repo_script" do
    assert_equal :repo_script, S.strategy_handler("repo_script")
  end

  test "strategy_handler maps github_actions" do
    # DevOps v2 Phase 2 — the hub deploys by dispatching a GitHub Actions workflow.
    assert_equal :github_actions, S.strategy_handler("github_actions")
  end

  # --- new_run_id: WHICH dispatched Actions run to watch -------------------

  test "new_run_id picks a run STRICTLY greater than the pre-dispatch snapshot" do
    assert_equal 101, S.new_run_id(100, 101)
  end

  test "new_run_id ignores a run that is not newer (the stale pre-existing run)" do
    # equal or smaller = the prior run `gh run list` returns until ours registers —
    # watching it would read a stale verdict, the exact false-green this prevents.
    assert_nil S.new_run_id(100, 100)
    assert_nil S.new_run_id(100, 99)
  end

  test "new_run_id treats a 0 before-snapshot as the genuine empty baseline" do
    # jq `// empty` → 0 means the workflow had NO prior runs; the first run is ours.
    assert_equal 5, S.new_run_id(0, 5)
  end

  test "new_run_id FAILS CLOSED on a nil before_id (the snapshot gh could not read)" do
    # A FAILED pre-dispatch `gh run list` must NEVER resolve a run — reading it as 0
    # would let the poll latch a pre-existing run and false-green a deploy.
    assert_nil S.new_run_id(nil, 101)
  end

  test "new_run_id FAILS CLOSED on a nil latest_id (a transient poll-read failure)" do
    # A transient list failure during the poll is SKIPPED, never compared.
    assert_nil S.new_run_id(100, nil)
  end

  # --- run_watch_verdict: the fallback watcher's per-poll STATE verdict --------
  #
  # After `gh run watch` dies on a TRANSIENT blip, the fallback re-reads the run's
  # own state and this pure classifier decides what that read MEANS. The bug it
  # fixes (run 29450907913, LIVE): the old fallback polled only for `completed`
  # and gave up after 100s — but a prod-deploy run PAUSED for the operator's
  # `production` approval reports `waiting` for HOURS (3h34m in the incident), so
  # a blip during that pause failed the ship CLOSED over a deploy that had simply
  # not been approved yet. A `waiting`/`queued`/`in_progress` run is LIVE, not
  # failed — the watcher must keep waiting, and this is where that is decided.

  test "[unit] run_watch_verdict treats a WAITING run as keep-waiting, NEVER failed" do
    # THE REGRESSION. `waiting` = paused for the production Environment's required
    # reviewer. It is the exact state the old fallback read as "never completed"
    # and failed closed on. It must be :pending (hold), never :failed.
    assert_equal :pending, S.run_watch_verdict("waiting", ""),
                 "a run paused for the operator's approval is LIVE, not a failed deploy"
    assert_equal :pending, S.run_watch_verdict("waiting", nil)
  end

  test "[unit] run_watch_verdict treats queued/in_progress (and any non-terminal) as pending" do
    %w[queued in_progress requested pending action_required].each do |status|
      assert_equal :pending, S.run_watch_verdict(status, nil),
                   "#{status} is a LIVE run — keep waiting, do not fail closed"
    end
    # A status GitHub might add that we don't recognize is still NOT `completed`,
    # so the run has not ended — treat it as live (keep waiting), never a verdict.
    assert_equal :pending, S.run_watch_verdict("some_new_state", nil)
  end

  test "[unit] run_watch_verdict returns :success ONLY on completed + success" do
    assert_equal :success, S.run_watch_verdict("completed", "success")
  end

  test "[unit] run_watch_verdict fails closed on a TERMINAL non-success conclusion" do
    # `completed` is the one terminal status; every non-success conclusion under it
    # is a genuine failed deploy → :failed → the ship fails closed PROMPTLY.
    %w[failure cancelled timed_out startup_failure action_required neutral stale skipped].each do |conclusion|
      assert_equal :failed, S.run_watch_verdict("completed", conclusion),
                   "completed+#{conclusion} is a real terminal failure — fail closed"
    end
    assert_equal :failed, S.run_watch_verdict("completed", ""),
                 "completed with an empty conclusion is not a success — fail closed, do not hang"
  end

  test "[unit] run_watch_verdict tolerates surrounding whitespace from the jq read" do
    assert_equal :success, S.run_watch_verdict(" completed ", " success ")
    assert_equal :pending, S.run_watch_verdict(" waiting ", "")
  end

  # --- approval_pause?: the run is specifically PAUSED for the operator ---------

  test "[unit] approval_pause? is true only for the waiting (required-reviewer) status" do
    assert S.approval_pause?("waiting"), "waiting = paused for the production approval"
    assert S.approval_pause?(" waiting "), "…tolerant of the jq read's whitespace"
    %w[queued in_progress completed requested].each do |status|
      assert_not S.approval_pause?(status), "#{status} is not the approval pause"
    end
    assert_not S.approval_pause?(nil)
  end

  # --- advance_accepted?: the post-ship origin/accepted re-baseline guard ------
  #
  # After a ship advances `main` to the frozen SHA, a repo on the accepted ladder
  # also fast-forwards its origin/accepted to that SHA — retiring the manual
  # `git push origin origin/main:refs/heads/accepted` the conductor ran by hand
  # after every ship. This pure guard decides IF that push happens; the ls-remote
  # existence probe and the fail-closed (no --force) ref push are the shell's.
  # DevOps v2 Phase 3, Slice 1.

  test "[unit] advance_accepted? advances with a frozen SHA and an existing origin/accepted" do
    assert S.advance_accepted?(sha: "abc123", accepted_exists: true)
  end

  test "[unit] advance_accepted? is a clean NO-OP for a repo without origin/accepted" do
    # rolio/turf pre-Phase-5 have no accepted branch — advance nothing.
    assert_not S.advance_accepted?(sha: "abc123", accepted_exists: false)
  end

  test "[unit] advance_accepted? never advances on a blank/nil SHA" do
    # The caller's main push aborts on a blank SHA, but the guard is honest alone.
    assert_not S.advance_accepted?(sha: "", accepted_exists: true)
    assert_not S.advance_accepted?(sha: "   ", accepted_exists: true)
    assert_not S.advance_accepted?(sha: nil, accepted_exists: true)
  end

  test "[unit] advance_accepted? requires BOTH — no SHA and no accepted is false" do
    assert_not S.advance_accepted?(sha: "", accepted_exists: false)
  end

  test "strategy_handler raises on an unknown strategy" do
    err = assert_raises(ArgumentError) { S.strategy_handler("rsync_box") }
    assert_match(/unknown prod_deploy strategy/, err.message)
    assert_match(/rsync_box/, err.message)
  end

  test "strategy_handler raises on nil/blank rather than silently skipping a deploy" do
    assert_raises(ArgumentError) { S.strategy_handler(nil) }
    assert_raises(ArgumentError) { S.strategy_handler("") }
  end

  # --- ordered_app_groups: hub first, rest stable --------------------------

  test "ordered_app_groups pulls the hub to the front" do
    groups = [{ "repo" => "turf-monster" }, { "repo" => "mcritchie-studio" }, { "repo" => "tax-studio" }]
    assert_equal %w[mcritchie-studio turf-monster tax-studio],
                 S.ordered_app_groups(groups).map { |g| g["repo"] }
  end

  test "ordered_app_groups keeps the non-hub order stable" do
    groups = [{ "repo" => "tax-studio" }, { "repo" => "turf-monster" }, { "repo" => "chain-ops" }]
    # No hub present — order is unchanged (stable).
    assert_equal %w[tax-studio turf-monster chain-ops],
                 S.ordered_app_groups(groups).map { |g| g["repo"] }
  end

  test "ordered_app_groups accepts symbol-keyed groups (record side) too" do
    groups = [{ repo: "turf-monster" }, { repo: "mcritchie-studio" }]
    assert_equal %w[mcritchie-studio turf-monster],
                 S.ordered_app_groups(groups).map { |g| g[:repo] }
  end

  test "ordered_app_groups handles an empty list" do
    assert_equal [], S.ordered_app_groups([])
  end

  # --- gems_to_repin: which published gems still branch-ref'd in a Gemfile --

  BRANCH_GEMFILE = <<~GEMFILE
    source "https://rubygems.org"
    gem "studio-engine", github: "amcritchie/studio-engine", branch: "feat/x"
    gem "solana-studio", "~> 0.4.7"
    gem "rails", "~> 7.2"
  GEMFILE

  test "gems_to_repin returns the branch-ref'd published gems" do
    assert_equal %w[studio-engine],
                 S.gems_to_repin(%w[studio-engine solana-studio], BRANCH_GEMFILE)
  end

  test "gems_to_repin excludes an already-pinned gem (idempotent)" do
    assert_equal [], S.gems_to_repin(%w[solana-studio], BRANCH_GEMFILE)
  end

  test "gems_to_repin excludes a gem absent from the Gemfile" do
    assert_equal [], S.gems_to_repin(%w[not-a-dep], BRANCH_GEMFILE)
  end

  test "gems_to_repin handles multiple branch-ref'd gems" do
    text = <<~GEMFILE
      gem "studio-engine", branch: "feat/a"
      gem "solana-studio", git: "https://github.com/amcritchie/solana-studio"
    GEMFILE
    assert_equal %w[studio-engine solana-studio],
                 S.gems_to_repin(%w[studio-engine solana-studio], text)
  end

  test "gems_to_repin returns [] for an empty published set" do
    assert_equal [], S.gems_to_repin([], BRANCH_GEMFILE)
  end

  # --- publish_needed?: RubyGems idempotency -------------------------------

  # The real /api/v1/versions/<gem>.json shape: an array of { "number" => ... }
  # entries, all LIVE — RubyGems excludes yanked versions from the listing
  # entirely (there is no `yanked` field). Other API fields are irrelevant here.
  REMOTE = [
    { "number" => "0.9.0" },
    { "number" => "0.8.0" }
  ].freeze

  test "publish_needed? is false when the version is already live (skip)" do
    assert_not S.publish_needed?("0.9.0", REMOTE)
  end

  test "publish_needed? is true when the version was never published" do
    assert S.publish_needed?("1.0.0", REMOTE)
  end

  test "publish_needed? is true for a version absent from the listing (e.g. yanked)" do
    # A yanked version is excluded from the listing, so it reads as not-live →
    # publish_needed? is true. Ship then attempts the push and RubyGems rejects
    # re-pushing a yanked number — yank safety lives at `gem push` (fail-closed),
    # since the listing carries no yanked flag to read.
    assert S.publish_needed?("0.8.1", REMOTE)
  end

  test "publish_needed? accepts a plain string listing (gem list shape)" do
    assert_not S.publish_needed?("0.9.0", %w[0.9.0 0.8.0])
    assert S.publish_needed?("1.0.0", %w[0.9.0 0.8.0])
  end

  test "publish_needed? is true against an empty (never-published) listing" do
    assert S.publish_needed?("0.1.0", [])
  end

  # --- frozen_sha: QA-frozen-SHA selection (present → freeze; absent → fall back) ---
  #
  # The decision behind bin/release's frozen_sha_for: ship the SHA `prepare` froze
  # under release.metadata["qa_shas"] when present, else signal (nil) the live
  # origin/release HEAD fallback. The Fix-1 change makes prepare freeze GEM repos
  # too, so a gem now resolves to its frozen SHA here instead of falling back.

  FROZEN = {
    "studio-engine" => "aaaaaaa1111111111111111111111111111111111",
    "mcritchie-studio" => "bbbbbbb2222222222222222222222222222222222"
  }.freeze

  test "frozen_sha returns the recorded SHA when the repo is in qa_shas (app)" do
    assert_equal FROZEN["mcritchie-studio"], S.frozen_sha(FROZEN, "mcritchie-studio")
  end

  test "frozen_sha returns the recorded SHA for a GEM repo (the Fix-1 guarantee)" do
    # Pre-fix, gems got no qa_shas entry → this fell back to origin/release HEAD
    # at ship time (drift-prone). Now the gem is frozen, so selection returns it.
    assert_equal FROZEN["studio-engine"], S.frozen_sha(FROZEN, "studio-engine")
  end

  test "frozen_sha returns nil to signal the live origin/release fallback when absent" do
    assert_nil S.frozen_sha(FROZEN, "solana-studio")
  end

  test "frozen_sha treats a blank recorded value as absent (fall back)" do
    assert_nil S.frozen_sha({ "studio-engine" => "" }, "studio-engine")
  end

  test "frozen_sha tolerates a nil qa_shas (fall back)" do
    assert_nil S.frozen_sha(nil, "studio-engine")
  end

  test "frozen_sha looks the repo up by string or symbol key" do
    assert_equal "ccc", S.frozen_sha({ "studio-engine" => "ccc" }, :"studio-engine")
    assert_equal "ddd", S.frozen_sha({ "studio-engine": "ddd" }, "studio-engine")
  end

  # --- preflight_offenders: which primaries are not on a clean `main` -------
  #
  # The pure detector behind bin/release's ship_preflight. It is NO LONGER a gate
  # for apps: the ship deploys from its own workspace and advances main by ref push,
  # so an app primary's state is not input (advisory_message says exactly that). It
  # still identifies the offenders the advisory names — and, for a gem repo, feeds
  # the one abort that survives (gem_build_offenders).

  def state(repo, branch: "main", dirty_files: [], tracked_dirty: nil)
    { "repo" => repo, "branch" => branch, "dirty_files" => dirty_files,
      "tracked_dirty" => tracked_dirty.nil? ? dirty_files : tracked_dirty }
  end

  test "preflight_offenders is empty when every app checkout is on a clean main" do
    states = [state("mcritchie-studio"), state("turf-monster")]
    assert_empty S.preflight_offenders(states), "clean main checkouts are safe to ff"
  end

  test "preflight_offenders flags a checkout on the wrong branch" do
    offenders = S.preflight_offenders([state("mcritchie-studio", branch: "pr-161")])
    assert_equal 1, offenders.size
    o = offenders.first
    assert_equal "mcritchie-studio", o["repo"]
    assert_equal "pr-161", o["branch"]
    assert_not o["on_main"]
    assert_not o["dirty"]
  end

  test "preflight_offenders flags a dirty main checkout with its files" do
    offenders = S.preflight_offenders([state("mcritchie-studio", dirty_files: ["db/schema.rb"])])
    assert_equal 1, offenders.size
    o = offenders.first
    assert o["on_main"]
    assert o["dirty"]
    assert_equal ["db/schema.rb"], o["dirty_files"]
  end

  test "preflight_offenders flags a checkout that is BOTH off-main AND dirty" do
    o = S.preflight_offenders([state("turf-monster", branch: "wip", dirty_files: ["a.rb"])]).first
    assert_not o["on_main"]
    assert o["dirty"]
  end

  test "preflight_offenders infers dirty from a non-empty dirty_files when no dirty flag" do
    o = S.preflight_offenders([{ "repo" => "x", "branch" => "main", "dirty_files" => ["f.rb"] }]).first
    assert o["dirty"], "dirty is inferred from the file list when not given explicitly"
  end

  test "preflight_offenders honors an explicit dirty flag over the file list" do
    o = S.preflight_offenders([{ "repo" => "x", "branch" => "main", "dirty" => true, "dirty_files" => [] }]).first
    assert o["dirty"], "an explicit dirty:true marks an offender even with no listed files"
  end

  test "preflight_offenders returns only the offenders out of a mixed batch" do
    states = [
      state("clean-app"),
      state("branch-app", branch: "pr-9"),
      state("dirty-app", dirty_files: ["x.rb"])
    ]
    assert_equal %w[branch-app dirty-app], S.preflight_offenders(states).map { |o| o["repo"] }
  end

  test "preflight_offenders accepts symbol-keyed states too" do
    offenders = S.preflight_offenders([{ repo: "x", branch: "pr-1", dirty_files: [] }])
    assert_equal "x", offenders.first["repo"]
  end

  # --- generated-artifact allowlist: a retro doc / the worktree ledger ------
  # ship_preflight must NOT count KNOWN-GENERATED files as dirt (a retro-*.md or
  # the delete-later.md ledger routinely sit uncommitted in the deploy checkout
  # and blocked EVERY ship's ff). Narrow allowlist — real code dirt still gates.

  test "generated_artifact? matches a retro doc and the worktree ledger only" do
    assert S.generated_artifact?("docs/agents/audits/retro-rel-20260624-b2f18e.md")
    assert S.generated_artifact?("docs/agents/maintenance/delete-later.md")
    # NOT a blanket docs/ ignore — any other doc/code still counts as dirt.
    assert_not S.generated_artifact?("docs/agents/audits/some-other-audit.md")
    assert_not S.generated_artifact?("docs/agents/maintenance/keep-this.md")
    assert_not S.generated_artifact?("app/models/release.rb")
    assert_not S.generated_artifact?("")
  end

  test "preflight_offenders ignores a clean-main checkout dirty ONLY with generated artifacts" do
    states = [state("mcritchie-studio", dirty_files: [
      "docs/agents/audits/retro-rel-20260624-b2f18e.md",
      "docs/agents/maintenance/delete-later.md"
    ])]
    assert_empty S.preflight_offenders(states),
                 "a retro doc + the worktree ledger are generated artifacts, not real dirt"
  end

  test "preflight_offenders still flags REAL dirt alongside a generated artifact" do
    o = S.preflight_offenders([state("mcritchie-studio", dirty_files: [
      "docs/agents/audits/retro-rel-1.md", "db/schema.rb"
    ])]).first
    assert o["dirty"], "a real dirty file still gates the ship"
    assert_equal ["db/schema.rb"], o["dirty_files"],
                 "the generated artifact is filtered out of the reported dirty files"
  end

  test "preflight_offenders still flags an off-main checkout even with only generated artifacts" do
    o = S.preflight_offenders([state("turf-monster", branch: "pr-9",
                                      dirty_files: ["docs/agents/maintenance/delete-later.md"])]).first
    assert_not o["on_main"], "off-main is still an offender regardless of the artifact allowlist"
  end

  # --- advisory_message: a dirty app primary is a NOTE, never a blocker -----
  #
  # The behavior change this task exists for. A dirty primary used to ABORT the
  # ship — which killed a real production deploy mid-train over a concurrent
  # session's staged work. The deploy no longer reads those trees, so the preflight
  # says so, prints the rescue, and ships.

  AT = Time.utc(2026, 7, 12, 21, 30, 0) # deterministic rescue branch names

  test "advisory_message is nil when every app primary is on a clean main" do
    assert_nil S.advisory_message(S.preflight_offenders([state("mcritchie-studio")])),
               "nothing to say — print nothing"
  end

  test "advisory_message says plainly that it is NOT a blocker and the tree is unread" do
    msg = S.advisory_message(S.preflight_offenders([state("turf-monster", dirty_files: ["app/x.rb"])]), at: AT)
    assert_match(/NOTE, not a blocker/, msg)
    assert_match(/does NOT read them/, msg, "it must say the ship ignores the primary")
    assert_match(/own workspace at the frozen SHA/, msg, "…and where it deploys from instead")
    assert_match(/turf-monster: .*dirty tree: app\/x\.rb/, msg)
  end

  test "advisory_message hands over the labeled-branch rescue, never a stash or a discard" do
    msg = S.advisory_message(S.preflight_offenders([state("turf-monster", dirty_files: ["app/x.rb"])]), at: AT)
    assert_match(%r{switch -c rescue/turf-monster-20260712-213000}, msg, "the rescue parks work on a labeled branch")
    assert_match(/commit -m 'rescue: stranded primary work'/, msg)
    assert_match(/switch main/, msg, "…and hands the primary back clean")
    assert_no_match(/git stash/, msg, "a stash is how a live session's work gets lost — never suggest one")
    assert_match(/Nothing here is discarded, and nothing is stashed/, msg, "it must promise the work survives")
  end

  test "the ship's OWN workspace is never counted as the operator's dirt" do
    # `git status` reports an untracked dir with a trailing slash. Every app repo
    # gitignores .worktrees/, but if a newly-onboarded one forgets, the ship's own
    # .worktrees/_ship would be named as stranded work — and the printed rescue
    # would COMMIT THE WORKSPACE INTO GIT. Caught on a real-git end-to-end run.
    assert S.generated_artifact?(".worktrees/"), "the untracked workspace dir is tooling output, not work"
    assert S.generated_artifact?(".worktrees/_ship/config/database.yml"), "…and anything under it"
    assert_empty S.preflight_offenders([state("turf-monster", dirty_files: [".worktrees/"])]),
                 "a ship must not report its own workspace as a dirty primary"
    assert_empty S.gem_build_offenders([state("studio-engine", tracked_dirty: [".worktrees/"])]),
                 "…nor let it gate a gem build"
    assert_not S.generated_artifact?("app/worktrees/x.rb"), "a lookalike path is still real dirt"
  end

  # --- gem_build_offenders: the ONE primary hazard that survives -------------
  #
  # A gem is BUILT from its primary checkout, and `gem build` packages what is on
  # disk — so a modified TRACKED file there would be PUBLISHED to RubyGems, where a
  # version can never be re-pushed. That is worth an abort. Untracked files are
  # invisible to the gemspec's `git ls-files`, so they are not, and gating on them
  # would just re-invent the abort class we removed.

  test "gem_build_offenders flags a gem primary with modified TRACKED files" do
    o = S.gem_build_offenders([state("studio-engine", tracked_dirty: ["lib/studio/version.rb"])]).first
    assert_equal "studio-engine", o["repo"]
    assert_equal ["lib/studio/version.rb"], o["dirty_files"]
  end

  test "gem_build_offenders ignores untracked files — gem build cannot package them" do
    states = [state("studio-engine", dirty_files: ["scratch.rb"], tracked_dirty: [])]
    assert_empty S.gem_build_offenders(states),
                 "an untracked scratch file is not in `git ls-files`, so it never reaches the .gem"
  end

  test "gem_build_offenders ignores the generated-artifact allowlist" do
    states = [state("solana-studio", tracked_dirty: ["docs/agents/maintenance/delete-later.md"])]
    assert_empty S.gem_build_offenders(states), "the worktree ledger is not real dirt"
  end

  test "gem_build_offenders does not care which branch a gem primary is on" do
    states = [state("studio-engine", branch: "pr-9", tracked_dirty: [])]
    assert_empty S.gem_build_offenders(states),
                 "the build detaches to the frozen SHA anyway — only ON-DISK dirt can corrupt the artifact"
  end

  test "gem_build_message leads with the stakes and hands over the rescue" do
    msg = S.gem_build_message(S.gem_build_offenders([state("studio-engine", tracked_dirty: ["lib/a.rb"])]), at: AT)
    assert_match(/BEFORE publishing anything/, msg, "the operator must know nothing is live yet")
    assert_match(/would be PUBLISHED/, msg)
    assert_match(/never be re-pushed/, msg, "…and that it is irreversible")
    assert_match(%r{switch -c rescue/studio-engine-20260712-213000}, msg)
    assert_match(/re-run `bin\/release ship`/, msg)
    assert_no_match(/git stash/, msg, "never offer a stash — the work may be a live session's")
    assert_match(/nothing is stashed and nothing is discarded/, msg)
  end

  test "gem_build_message truncates a long dirty file list" do
    files = (1..9).map { |i| "f#{i}.rb" }
    msg = S.gem_build_message(S.gem_build_offenders([state("x", tracked_dirty: files)]), at: AT)
    assert_match(/\(\+4 more\)/, msg, "only the first 5 files are listed, then a +N more")
  end

  # --- rescue_commands: commit to a labeled branch; never stash, never discard --

  test "rescue_commands parks dirty work on a timestamped branch and returns to main" do
    cmds = S.rescue_commands({ "repo" => "turf-monster", "dirty" => true }, at: AT)
    assert_equal 3, cmds.length
    assert_match(%r{switch -c rescue/turf-monster-20260712-213000}, cmds[0])
    assert_match(/add -A/, cmds[1])
    assert_match(/commit -m 'rescue: stranded primary work'/, cmds[1])
    assert_match(/switch main/, cmds[2])
  end

  test "rescue_commands takes an injectable root so the paths are paste-ready" do
    cmds = S.rescue_commands({ "repo" => "turf-monster", "dirty" => true }, at: AT, root: "/Users/alex/projects")
    assert_match(%r{git -C /Users/alex/projects/turf-monster switch -c rescue/}, cmds[0])
    assert(cmds.none? { |c| c.include?("<projects>") },
           "an operator must not hand-substitute a path at the worst possible moment")
  end

  test "rescue_commands for a CLEAN off-main checkout is just a checkout" do
    cmds = S.rescue_commands({ "repo" => "turf-monster", "dirty" => false }, at: AT)
    assert_equal 1, cmds.length
    assert_match(/checkout main/, cmds[0])
    assert_no_match(/rescue\//, cmds[0], "nothing to rescue — there is no uncommitted work")
  end

  # --- ship_gate_skip?: G4 self-gating against the G3 batch certification ----
  #
  # G4 may skip its suite ONLY against G3's OWN recorded verdict
  # (release.metadata["qa_gates"][repo]), never against the registry or the
  # deployed SHA. See ship_gate_skip? for the disarm bug that rule closes.

  # The shape pre_qa_gate records after a GREEN suite.
  def certified(sha: "abc123", cmd: "bin/rails test", ok: true)
    { "sha" => sha, "cmd" => cmd, "ok" => ok }
  end

  test "[unit] ship_gate_skip? skips when G3 certified this exact command on this exact SHA" do
    assert S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123",
                             qa_gate: certified),
           "G3 recorded a green run of the same command on the same SHA — re-running proves nothing"
  end

  # --- the SAFETY REGRESSION: a G3 that never ran must not certify anything ---
  #
  # THIS IS THE BUG. The old predicate compared the REGISTRY (test_cmd ==
  # qa_test_cmd) against the DEPLOYED sha (qa_shas) — and `qa_shas` is stamped by
  # the QA deploy loop, not by the gate. So the documented gate-skip recipe
  # (comment out qa_test_cmd so G3 skips → restore the file before ship, because
  # ship's preflight refuses a dirty primary) left the registry reading equal
  # again at ship, the deployed SHA matching, and G4 SKIPPING a suite that NOTHING
  # ever ran. Skipping G3 silently disarmed the production gate.
  #
  # Under the new contract there is no record, so G4 fails open and runs.
  test "[unit] ship_gate_skip? does NOT skip when G3 never recorded a verdict (the disarm bug)" do
    assert_not S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123", qa_gate: nil),
               "no G3 record = no certification: skipping here would disarm the production gate"
    assert_not S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123", qa_gate: {}),
               "an empty record certifies nothing — the gate must run"
  end

  test "[unit] ship_gate_skip? does NOT skip on a RED recorded G3 verdict" do
    assert_not S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123",
                                 qa_gate: certified(ok: false)),
               "G3 went red — that is the opposite of a certification"
  end

  # --- the AUDITOR arms G4, in the FAIL-OPEN direction only --------------------
  #
  # THE HOLE THIS CLOSES: on a green G3 the frozen ship SHA *is* the certified SHA,
  # so ship_gate_skip? matched and G4 SKIPPED its suite — meaning in the gate-GREEN
  # + CI-RED direction (the dangerous one the cross-check exists for) the G3 alarm
  # was the ONLY thing between that commit and production, while the alarm text
  # told the operator G4 would re-gate it. A gate system that claims a backstop it
  # does not have makes its own alarm dismissible. Now a red auditor DISTRUSTS the
  # certification and the suite genuinely re-runs on the frozen SHA.
  #
  # FAIL-OPEN ONLY: the auditor may cause MORE checking, NEVER a block. Only the
  # literal "red" arms it; every no-data state changes nothing.
  test "[unit] ship_gate_skip? does NOT skip when the AUDITOR called the certified SHA red" do
    audited = certified.merge("ci" => { "state" => "red", "checks" => ["test:system"] })

    assert_not S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123", qa_gate: audited),
               "G3 said green, GitHub CI said RED for that SAME SHA — the batch certification is exactly " \
               "what must not be trusted, so G4 fails open and re-runs the suite"
    assert S.auditor_red?(audited)
  end

  test "[unit] NO-DATA from the auditor never arms G4 — silence is not a red" do
    # none/pending/unverified = GitHub had nothing to say (today ci.yml doesn't even
    # build `release`). If any of these re-triggered the gate, the cross-check would
    # tax every ship with a redundant suite for a verdict nobody gave.
    %w[none pending unverified].each do |state|
      audited = certified.merge("ci" => { "state" => state })

      assert S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123", qa_gate: audited),
             "a #{state} auditor is NO DATA — it must not change the skip decision"
      assert_not S.auditor_red?(audited)
    end

    green = certified.merge("ci" => { "state" => "green", "count" => 4 })
    assert S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123", qa_gate: green),
           "both verdicts agree green — nothing to re-check"
  end

  test "[unit] auditor_red? is false for a record with no auditor at all (pre-cross-check releases)" do
    # Every release recorded before the cross-check landed has a ci-less gate record.
    # It must keep self-gating exactly as before — a missing auditor is not a red one.
    assert_not S.auditor_red?(certified)
    assert_not S.auditor_red?(certified.merge("ci" => nil))
    assert_not S.auditor_red?(nil)
    assert S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123", qa_gate: certified)
  end

  test "[unit] a CREDITED G3 record self-skips and never arms the disagree path" do
    # task dedupe-hub-release-suite: on a fast-forwarded promote the G3 gate may
    # credit the SHA's existing green conclusion, recording the credited source in
    # the gate note ("credited"). That is still a GREEN certification of the same
    # command on the same SHA — G4 self-skips against it exactly as against a
    # polled one, and the extra key must neither break the skip nor read as a
    # DISAGREE (auditor_red? stays literal-"red"-only).
    credited = certified.merge("ci" => { "state" => "green", "count" => 2,
                                         "credited" => "2 completed check-runs already green; fast-forward promote" })

    assert S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123", qa_gate: credited),
           "a credited green record is the same proof ship_gate_skip? already accepts"
    assert_not S.auditor_red?(credited), "a credited green must never arm the disagree/re-gate path"
  end

  test "[unit] a TREE-credited G3 record self-skips and never arms the disagree path" do
    # task dedupe-hub-release-suite round 2: the LIVE batch-PR promote mints a NEW
    # merge SHA, so the credit's evidence is the ACCEPTED head's green vouching for
    # the IDENTICAL TREE (bin/release's ci_tree_credit_verdict), recorded with both
    # SHAs + the shared tree in the note. The record still certifies THIS repo,
    # THIS cmd, THIS (release) SHA with a green ci.state — G4 self-skips against
    # it exactly as against a polled or same-SHA-credited one, and the richer
    # credited prose must neither break the skip nor read as a DISAGREE.
    tree_credited = certified.merge(
      "ci" => { "state" => "green", "count" => 8,
                "credited" => "tree-identical promote — accepted head 5b10402d… concluded green and " \
                              "shares tree 5b1c78e0… with release abc123" }
    )

    assert S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123", qa_gate: tree_credited),
           "a tree-credited green record is the same proof ship_gate_skip? already accepts"
    assert_not S.auditor_red?(tree_credited), "a tree-credited green must never arm the disagree/re-gate path"
  end

  # NOTE — the other half of the fail-open contract ("a red auditor can never BLOCK
  # a ship, it only makes the gate RUN") is not assertable here: ship_gate_skip? is
  # a pure run/skip decision and has no way to express an abort. It is proven where
  # it actually lives — test/lib/release_cli_test.rb's
  # test_ship_test_gate_names_the_red_auditor_as_the_reason_it_is_re_running, which
  # drives the REAL test_gate with a red-auditor record and asserts the suite RAN
  # and the gate still PASSED. (A unit test named for that property here would only
  # re-assert `skip? == false` under a grander name — a test whose name claims more
  # than it checks is its own small lying gate.)

  test "[unit] ship_gate_skip? re-triggers on SHA drift (straggler / re-pin)" do
    assert_not S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123",
                                 qa_gate: certified(sha: "def456")),
               "G3 certified a DIFFERENT commit — the frozen ship SHA is uncertified"
  end

  test "[unit] ship_gate_skip? re-triggers when G3 ran a narrower command" do
    # A satellite whose G3 ran only the integration subset still gets its full
    # suite at ship — a subset run certifies nothing about the full test_cmd.
    assert_not S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "abc123",
                                 qa_gate: certified(cmd: "bin/rails test test/integration"))
  end

  test "[unit] ship_gate_skip? never skips on blank inputs (fail open: run the gate)" do
    assert_not S.ship_gate_skip?(test_cmd: "", frozen_sha: "abc", qa_gate: certified(sha: "abc", cmd: ""))
    assert_not S.ship_gate_skip?(test_cmd: "bin/rails test", frozen_sha: "", qa_gate: certified(sha: ""))
    assert_not S.ship_gate_skip?(test_cmd: nil, frozen_sha: nil, qa_gate: nil)
  end

  # --- qa_gate: pluck a repo's recorded G3 verdict --------------------------

  test "[unit] qa_gate reads a repo's recorded G3 verdict, string or symbol keyed" do
    gates = { "mcritchie-studio" => certified }
    assert_equal certified, S.qa_gate(gates, "mcritchie-studio")
    assert_equal certified, S.qa_gate(gates.symbolize_keys, :"mcritchie-studio")
  end

  test "[unit] qa_gate returns nil for a repo G3 never certified" do
    assert_nil S.qa_gate({ "mcritchie-studio" => certified }, "turf-monster")
    assert_nil S.qa_gate(nil, "mcritchie-studio")
    assert_nil S.qa_gate({ "mcritchie-studio" => "green" }, "mcritchie-studio"),
               "a non-Hash record is not a verdict"
  end
  # --- resumable_repin?: idempotency BY IDENTITY (the partial-ship retry) -----
  #
  # A ship that published the gems, pushed the re-pin, then died leaves
  # origin/release = repin1 while qa_shas still says frozen. The retry must
  # RECOGNIZE that commit as its own and ship it — minting a rival (same tree, new
  # commit object) is a non-fast-forward that can never land, and the old code
  # instead read its own re-pin as un-QA'd drift and wedged the ship AFTER the gems
  # published. It qualifies on all three or not at all.

  FROZEN_GEMFILE   = %(source "https://rubygems.org"\ngem "studio-engine", github: "a/b", branch: "x"\n)
  EXPECTED_GEMFILE = %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.9"\n)

  test "resumable_repin? accepts the re-pin this run would have written" do
    assert S.resumable_repin?(ancestor: true, changed_files: ["Gemfile", "Gemfile.lock"],
                              head_gemfile: EXPECTED_GEMFILE, expected_gemfile: EXPECTED_GEMFILE)
  end

  test "resumable_repin? REFUSES a head that is not a descendant of the frozen SHA" do
    assert_not S.resumable_repin?(ancestor: false, changed_files: ["Gemfile"],
                                  head_gemfile: EXPECTED_GEMFILE, expected_gemfile: EXPECTED_GEMFILE),
               "a divergent line of development is not a re-pin"
  end

  test "resumable_repin? REFUSES when code rode along with the Gemfile" do
    assert_not S.resumable_repin?(ancestor: true, changed_files: ["Gemfile", "Gemfile.lock", "app/models/x.rb"],
                                  head_gemfile: EXPECTED_GEMFILE, expected_gemfile: EXPECTED_GEMFILE),
               "this is the original guard's whole point: no code reaches prod un-QA'd under cover of a re-pin"
  end

  test "resumable_repin? REFUSES a Gemfile pinned to a version this ship did not publish" do
    wrong = %(source "https://rubygems.org"\ngem "studio-engine", "~> 0.7"\n)
    assert_not S.resumable_repin?(ancestor: true, changed_files: ["Gemfile"],
                                  head_gemfile: wrong, expected_gemfile: EXPECTED_GEMFILE),
               "'no branch ref left' is NOT 'this is my re-pin' — a weaker test ships the wrong gem to prod"
  end

  test "resumable_repin? REFUSES a still-branch-ref'd Gemfile" do
    assert_not S.resumable_repin?(ancestor: true, changed_files: ["Gemfile"],
                                  head_gemfile: FROZEN_GEMFILE, expected_gemfile: EXPECTED_GEMFILE)
  end

  test "resumable_repin? REFUSES an empty diff — nothing was re-pinned at all" do
    assert_not S.resumable_repin?(ancestor: true, changed_files: [],
                                  head_gemfile: EXPECTED_GEMFILE, expected_gemfile: EXPECTED_GEMFILE)
  end

  test "resumable_repin? REFUSES a blank expected Gemfile rather than matching on nothing" do
    assert_not S.resumable_repin?(ancestor: true, changed_files: ["Gemfile"],
                                  head_gemfile: "", expected_gemfile: "")
  end

  test "resumable_repin? tolerates the newlines of `git diff --name-only` output" do
    assert S.resumable_repin?(ancestor: true, changed_files: ["Gemfile\n", "Gemfile.lock\n"],
                              head_gemfile: EXPECTED_GEMFILE, expected_gemfile: EXPECTED_GEMFILE)
  end
end
