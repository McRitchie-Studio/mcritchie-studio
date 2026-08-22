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

  # --- approval_pause?: the run is PAUSED on a deployment-protection gate --------

  test "[unit] approval_pause? is true only for the waiting (deployment-protection) status" do
    assert S.approval_pause?("waiting"), "waiting = held on a deployment-protection gate"
    assert S.approval_pause?(" waiting "), "…tolerant of the jq read's whitespace"
    %w[queued in_progress completed requested].each do |status|
      assert_not S.approval_pause?(status), "#{status} is not the protection pause"
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

  # --- accepted_relation: WHY the fail-closed advance refused ------------------
  #
  # REGRESSION (rel-20260720-1fc111): when the advance refused a non-fast-forward
  # the CLI called it "DIVERGED" unconditionally and suggested
  # `git push origin <sha>:refs/heads/accepted` — a bare ref push that would have
  # DESTROYED two PRs a concurrent review pass merged into accepted mid-ship.
  # accepted was not diverged; it was AHEAD. This classifier owns that verdict.
  #
  # The topological subtlety: the sweep merges accepted INTO release, so `main`
  # ends up a MERGE COMMIT whose tree equals the accepted head it came from, and
  # that merge commit never appears in accepted's history. Plain ancestry is
  # therefore FALSE even though accepted is missing nothing — so absorption is
  # judged on CONTENT (main's tree present in accepted's history) as well.

  test "[unit] accepted_relation calls a plain ancestor main AHEAD" do
    assert_equal :ahead, S.accepted_relation(main_is_ancestor: :affirmed, main_tree_absorbed: :refuted)
  end

  test "[unit] accepted_relation calls an absorbed main tree AHEAD despite refuted ancestry" do
    # THE REGRESSION SHAPE: sweep-merge main is no ancestor of accepted, but its
    # tree is already in accepted's history — nothing is missing, advise nothing.
    assert_equal :ahead, S.accepted_relation(main_is_ancestor: :refuted, main_tree_absorbed: :affirmed)
  end

  test "[unit] accepted_relation calls accepted DIVERGED only when BOTH signals are refuted" do
    # Proven-absent content — not merely unproven-present. This is also the
    # post-#588 gem-carrying-release shape: the lock bump genuinely refutes the tree.
    assert_equal :diverged, S.accepted_relation(main_is_ancestor: :refuted, main_tree_absorbed: :refuted)
  end

  test "[unit] accepted_relation is AHEAD when both signals are affirmed" do
    assert_equal :ahead, S.accepted_relation(main_is_ancestor: :affirmed, main_tree_absorbed: :affirmed)
  end

  # --- ABSENCE of signal is NOT a negative signal -------------------------------
  #
  # The original defect WAS this shape: a non-fast-forward (which only says "not a
  # fast-forward") was read as "accepted has diverged". Collapsing an unreadable
  # git state into :refuted would rebuild that bug one layer down, so an unreadable
  # signal must surface as :unknown and never manufacture a confident verdict.

  test "[unit] accepted_relation reports UNKNOWN when a signal could not be read" do
    assert_equal :unknown, S.accepted_relation(main_is_ancestor: :unknown, main_tree_absorbed: :refuted)
    assert_equal :unknown, S.accepted_relation(main_is_ancestor: :refuted, main_tree_absorbed: :unknown)
    assert_equal :unknown, S.accepted_relation(main_is_ancestor: :unknown, main_tree_absorbed: :unknown)
  end

  test "[unit] accepted_relation never downgrades AFFIRMED evidence to unknown" do
    # Positive proof of absorption settles it; a second unreadable signal cannot
    # subtract from evidence already in hand.
    assert_equal :ahead, S.accepted_relation(main_is_ancestor: :affirmed, main_tree_absorbed: :unknown)
    assert_equal :ahead, S.accepted_relation(main_is_ancestor: :unknown, main_tree_absorbed: :affirmed)
  end

  test "[unit] accepted_relation never calls an unreadable state DIVERGED" do
    # The safety property, asserted positively: :diverged is reachable ONLY from
    # two refutations, so no combination containing an :unknown can produce it.
    signals = %i[affirmed refuted unknown]
    signals.product(signals).each do |ancestor, absorbed|
      next unless [ancestor, absorbed].include?(:unknown)

      assert_not_equal :diverged, S.accepted_relation(main_is_ancestor: ancestor, main_tree_absorbed: absorbed),
                       "an unreadable signal (#{ancestor}/#{absorbed}) must never yield a confident DIVERGED"
    end
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

  # --- deploy_target?: "no production app" is a CASE, not a misconfiguration ---
  #
  # The 2026-08-22 wedge: chain-ops declared an adapter for a deploy target it
  # did not have. With the adapter gone, ship must SKIP its dispatch cleanly —
  # it still advances main — instead of aborting the whole release mid-ship.

  test "deploy_target? is false when no prod_deploy is declared" do
    assert_not S.deploy_target?(nil)
    assert_not S.deploy_target?({})
    assert_not S.deploy_target?({ "strategy" => "" })
    assert_not S.deploy_target?({ "strategy" => "   " })
  end

  test "deploy_target? is true for every known strategy" do
    S::STRATEGY_HANDLERS.each_key do |strategy|
      assert S.deploy_target?({ "strategy" => strategy }), "#{strategy} is a real deploy target"
    end
  end

  # The line between the two failure modes: a MISSING adapter means "nothing to
  # deploy"; a TYPO must still blow up. Reading a typo as "nothing to deploy"
  # would turn a misconfigured app into a silently-never-deployed one.
  test "deploy_target? is true for an unknown strategy so a typo still reaches strategy_handler" do
    assert S.deploy_target?({ "strategy" => "rsync_box" })
    assert_raises(ArgumentError) { S.strategy_handler("rsync_box") }
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
    gem "studio-engine", github: "McRitchie-Studio/studio-engine", branch: "feat/x"
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
      gem "solana-studio", git: "https://github.com/McRitchie-Studio/solana-studio"
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
    # the IDENTICAL TREE (bin/release's tree_identical_ci_outcome), recorded with both
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

  # --- deploy_already_succeeded?: is the frozen SHA already live on prod? ------
  #
  # The guard both `bin/release finalize` and a `ship` RE-RUN turn on after a
  # watch-process kill left a github_actions deploy landed but the board stranded.

  test "deploy_already_succeeded? (github_actions) is TRUE only when main+/up+run all confirm" do
    assert S.deploy_already_succeeded?(strategy: "github_actions",
                                       main_at_sha: true, up_ok: true, run_success: true)
  end

  test "deploy_already_succeeded? (github_actions) FAILS CLOSED when the SHA's run did not succeed" do
    # main advanced and prod is up, but the deploy run for the SHA is not a success
    # — main+/up alone can be a stale prod serving the old build. Never mark shipped.
    assert_not S.deploy_already_succeeded?(strategy: "github_actions",
                                           main_at_sha: true, up_ok: true, run_success: false)
    assert_not S.deploy_already_succeeded?(strategy: "github_actions",
                                           main_at_sha: true, up_ok: true, run_success: nil)
  end

  test "deploy_already_succeeded? (github_actions) FAILS CLOSED when main is not at the SHA" do
    assert_not S.deploy_already_succeeded?(strategy: "github_actions",
                                           main_at_sha: false, up_ok: true, run_success: true)
  end

  test "deploy_already_succeeded? (github_actions) does NOT skip a FIRST ship (main advanced, run not yet)" do
    # The first-ship state at the skip check: push_frozen_main advanced main (true)
    # and prod /up serves the OLD build (200), but NO prod-deploy run for the frozen
    # SHA has succeeded yet (the dispatch is still ahead) → run_success false → deploy.
    assert_not S.deploy_already_succeeded?(strategy: "github_actions",
                                           main_at_sha: true, up_ok: true, run_success: false)
  end

  test "deploy_already_succeeded? FAILS CLOSED when prod /up is not 200 (every strategy)" do
    assert_not S.deploy_already_succeeded?(strategy: "github_actions",
                                           main_at_sha: true, up_ok: false, run_success: true)
    assert_not S.deploy_already_succeeded?(strategy: "git_push_heroku",
                                           up_ok: false, deployed_at_sha: true)
    assert_not S.deploy_already_succeeded?(strategy: "repo_script",
                                           up_ok: false, deployed_at_sha: true)
  end

  test "deploy_already_succeeded? (git_push_heroku) needs a deployed-marker, NOT main_at_sha" do
    # THE FIRST-SHIP TRAP: push_frozen_main advances origin/main to the frozen SHA
    # BEFORE the Heroku push, so main_at_sha is true on a FIRST ship while prod still
    # serves the OLD build (its /up still 200). main+/up must NOT read as deployed —
    # only the Heroku release SHA (deployed_at_sha) proves the new build is live.
    assert S.deploy_already_succeeded?(strategy: "git_push_heroku", up_ok: true, deployed_at_sha: true)
    assert_not S.deploy_already_succeeded?(strategy: "git_push_heroku", up_ok: true, main_at_sha: true)
    assert_not S.deploy_already_succeeded?(strategy: "git_push_heroku", up_ok: true, deployed_at_sha: nil)
  end

  test "deploy_already_succeeded? (repo_script) needs a deployed-marker at the SHA, not main" do
    # Same first-ship trap: push_frozen_main advances main BEFORE the repo's script
    # runs, so main alone proves nothing; require the repo's own deployed marker.
    assert S.deploy_already_succeeded?(strategy: "repo_script", up_ok: true, deployed_at_sha: true)
    assert_not S.deploy_already_succeeded?(strategy: "repo_script", up_ok: true, main_at_sha: true)
    assert_not S.deploy_already_succeeded?(strategy: "repo_script", up_ok: true, deployed_at_sha: nil)
  end

  test "deploy_already_succeeded? is FALSE for an unknown strategy (never ship an unrecognized deploy)" do
    assert_not S.deploy_already_succeeded?(strategy: "carrier_pigeon",
                                           main_at_sha: true, up_ok: true, run_success: true)
  end

  # --- prod_run_succeeded?: pick the SHA's prod-deploy run out of `gh run list` ---

  test "prod_run_succeeded? is TRUE when a run at the SHA is completed+success" do
    runs = [{ "headSha" => "abc123", "status" => "completed", "conclusion" => "success" }]
    assert S.prod_run_succeeded?(runs, "abc123")
  end

  test "prod_run_succeeded? ignores runs for a DIFFERENT SHA (a prior prod deploy)" do
    runs = [{ "headSha" => "oldsha", "status" => "completed", "conclusion" => "success" }]
    assert_not S.prod_run_succeeded?(runs, "abc123")
  end

  test "prod_run_succeeded? is FALSE when the SHA's run failed or is still in flight" do
    failed  = [{ "headSha" => "abc123", "status" => "completed", "conclusion" => "failure" }]
    waiting = [{ "headSha" => "abc123", "status" => "waiting", "conclusion" => nil }]
    assert_not S.prod_run_succeeded?(failed, "abc123")
    assert_not S.prod_run_succeeded?(waiting, "abc123")
  end

  test "prod_run_succeeded? finds the matching run among several, and reads symbol keys" do
    runs = [
      { "headSha" => "oldsha", "status" => "completed", "conclusion" => "success" },
      { headSha: "abc123", status: "completed", conclusion: "success" }
    ]
    assert S.prod_run_succeeded?(runs, "abc123")
  end

  test "prod_run_succeeded? FAILS CLOSED on a blank sha or an empty list" do
    assert_not S.prod_run_succeeded?([{ "headSha" => "abc123", "status" => "completed", "conclusion" => "success" }], "")
    assert_not S.prod_run_succeeded?([], "abc123")
    assert_not S.prod_run_succeeded?(nil, "abc123")
  end

  # --- finalize_pending?: which record+seal+install steps the killed ship skipped -

  test "finalize_pending? lists ALL steps for a fully-stranded release (kill before step 6)" do
    # The exact strand: deploy landed, but seal/ship!/notes never ran → board at assembled.
    assert_equal %i[seal ship notes],
                 S.finalize_pending?(state: "assembled", sealed: false, notes_completed: false)
  end

  test "finalize_pending? is EMPTY on an already-finalized release (a clean no-op)" do
    # THE IDEMPOTENCY GUARD: a second finalize must not re-seal, re-ship, or re-post.
    assert_equal [], S.finalize_pending?(state: "shipped", sealed: true, notes_completed: true)
  end

  test "finalize_pending? still includes :ship when members are unflipped (kill MID-cadence)" do
    # state=shipped but a straggler member remains → Release#ship! RESUMES it (safe),
    # so :ship must stay pending; dropping it would leave the member stranded.
    assert_equal %i[ship], S.finalize_pending?(state: "shipped", sealed: true,
                                               notes_completed: true, members_all_shipped: false)
  end

  test "finalize_pending? drops :ship only when shipped AND every member is flipped" do
    # Release#ship! raises 'already terminal' ONLY here — which is exactly when :ship drops.
    assert_not_includes S.finalize_pending?(state: "shipped", sealed: true,
                                            notes_completed: true, members_all_shipped: true), :ship
  end

  test "finalize_pending? returns ONLY :notes when the kill landed between ship! and notes" do
    # shipped + sealed but notes never delivered → post notes, nothing else (no double records).
    assert_equal %i[notes],
                 S.finalize_pending?(state: "shipped", sealed: true, notes_completed: false)
  end

  test "finalize_pending? returns :ship and :notes when the kill landed after the seal" do
    assert_equal %i[ship notes],
                 S.finalize_pending?(state: "assembled", sealed: true, notes_completed: false)
  end

  test "finalize_pending? keeps the seal→ship→notes order so notes read the seal verdict" do
    # The order is load-bearing: the live ship records the seal (5c) before ship!+notes (6).
    assert_equal %i[seal ship notes], S.finalize_pending?(state: "assembled", sealed: false, notes_completed: false)
  end

  # MUTATION CHECK on the idempotency guard: flip the `notes` done-test from
  # `== true` to a truthy test (or drop it) and an already-finalized release would
  # report :notes pending, re-delivering the Discord notes. This vector — the
  # notes NOT completed — must produce :notes, and the completed vector must not.
  test "finalize_pending? idempotency guard is EXACT: notes_completed=false ⇒ :notes, true ⇒ none" do
    assert_includes S.finalize_pending?(state: "shipped", sealed: true, notes_completed: false), :notes
    assert_not_includes S.finalize_pending?(state: "shipped", sealed: true, notes_completed: true), :notes
    # and a non-boolean truthy value is NOT treated as done (guard is `== true`).
    assert_includes S.finalize_pending?(state: "shipped", sealed: true, notes_completed: "yes"), :notes
  end

  # --- consumer_bump_action: the prepare-side per-gem Gemfile decision ---------

  test "consumer_bump_action is :absent when the Gemfile never declares the gem" do
    assert_equal :absent, S.consumer_bump_action(%(gem "rails", "~> 7.2"\n), "studio-engine", "0.11.0")
  end

  test "consumer_bump_action is :rewrite_source for a branch-ref'd line" do
    text = %(gem "studio-engine", github: "McRitchie-Studio/studio-engine", branch: "feat/x"\n)
    assert_equal :rewrite_source, S.consumer_bump_action(text, "studio-engine", "0.11.0")
  end

  test "consumer_bump_action is :lock_only when the pin already allows the version" do
    # The standard case: the house `~> major.minor` pin holds the MAJOR, so both
    # a patch (0.10.5) and a minor bump (0.11.0) are lock-only.
    assert_equal :lock_only, S.consumer_bump_action(%(gem "studio-engine", "~> 0.10"\n), "studio-engine", "0.10.5")
    assert_equal :lock_only, S.consumer_bump_action(%(gem "studio-engine", "~> 0.10"\n), "studio-engine", "0.11.0")
  end

  test "consumer_bump_action is :rewrite_pin when the version escapes the constraint" do
    # A major bump escapes `~> 0.10`; a minor bump escapes a three-segment pin.
    assert_equal :rewrite_pin, S.consumer_bump_action(%(gem "studio-engine", "~> 0.10"\n), "studio-engine", "1.0.0")
    assert_equal :rewrite_pin, S.consumer_bump_action(%(gem "studio-engine", "~> 0.10.0"\n), "studio-engine", "0.11.0")
    assert_equal :rewrite_pin, S.consumer_bump_action(%(gem "studio-engine", "0.10.0"\n), "studio-engine", "0.10.1")
  end

  test "consumer_bump_action is :lock_only for a bare declaration" do
    assert_equal :lock_only, S.consumer_bump_action(%(gem "studio-engine"\n), "studio-engine", "9.9.9")
  end

  test "consumer_bump_action NEVER rewrites a pin DOWNWARD for a backward version" do
    # The invariant is UPWARD-ONLY, the silent-downgrade sibling of stranded_gem_work?. A
    # version BELOW the pin floor escapes the constraint too, but rewriting the pin down to it
    # is a production downgrade. It must be :lock_only (pin left as-is), never :rewrite_pin.
    # Mutation evidence: the pre-fix `constraint_allows? ? :lock_only : :rewrite_pin` returned
    # :rewrite_pin here and `bumped_gemfile` rewrote `~> 0.10` DOWN to `~> 0.9`.
    assert_equal :lock_only, S.consumer_bump_action(%(gem "studio-engine", "~> 0.10"\n), "studio-engine", "0.9.0")
    assert_equal :lock_only, S.consumer_bump_action(%(gem "studio-engine", "0.10.0"\n), "studio-engine", "0.9.9")
    pinned = %(gem "studio-engine", "~> 0.10"\n)
    assert_equal pinned, S.bumped_gemfile(pinned, "studio-engine", "0.9.0"),
                 "a backward version leaves the Gemfile pin untouched — no downgrade"
  end

  test "bumped_gemfile rewrites only what the action demands" do
    pinned = %(gem "studio-engine", "~> 0.10"\n)
    # escape (major bump) → the pin advances
    assert_equal %(gem "studio-engine", "~> 1.0"\n), S.bumped_gemfile(pinned, "studio-engine", "1.0.0")
    # within constraint (patch AND minor under the house pin) → untouched (lock-only)
    assert_equal pinned, S.bumped_gemfile(pinned, "studio-engine", "0.10.5")
    assert_equal pinned, S.bumped_gemfile(pinned, "studio-engine", "0.11.0")
    # source ref → re-pinned to the published version
    branchy = %(gem "studio-engine", github: "McRitchie-Studio/studio-engine", branch: "feat/x"\n)
    assert_equal %(gem "studio-engine", "~> 0.11"\n), S.bumped_gemfile(branchy, "studio-engine", "0.11.0")
    # absent → untouched
    other = %(gem "rails", "~> 7.2"\n)
    assert_equal other, S.bumped_gemfile(other, "studio-engine", "0.11.0")
  end

  # --- stranded_gem_work?: the prepare-side silent-skip guard ------------------

  test "stranded_gem_work? BLOCKS commits past the tag with an unbumped version" do
    assert S.stranded_gem_work?(ahead_commits: ["abc123 engine fix"], version: "0.10.0", tag_version: "0.10.0"),
           "an unbumped version_file over new commits is the silent publish-skip that strands work"
  end

  test "stranded_gem_work? passes a bumped version over new commits" do
    assert_not S.stranded_gem_work?(ahead_commits: ["abc123 engine fix"], version: "0.11.0", tag_version: "0.10.0")
  end

  test "stranded_gem_work? passes when release is level with the tag" do
    # The idempotent re-run: prepare already published + tagged this tip.
    assert_not S.stranded_gem_work?(ahead_commits: [], version: "0.11.0", tag_version: "0.11.0")
  end

  test "stranded_gem_work? passes a never-published repo (no tag)" do
    assert_not S.stranded_gem_work?(ahead_commits: ["abc123 first commit"], version: "0.1.0", tag_version: "")
    assert_not S.stranded_gem_work?(ahead_commits: ["abc123 first commit"], version: "0.1.0", tag_version: nil)
  end

  test "stranded_gem_work? ignores blank commit lines" do
    assert_not S.stranded_gem_work?(ahead_commits: ["", "  ", nil], version: "0.10.0", tag_version: "0.10.0")
  end

  # --- the PRODUCTION DOWNGRADE vector (round-5 blocker) ----------------------
  #
  # The guard's invariant is NOT "version equals the tag" — it is "the release
  # version is STRICTLY NEWER than the last published tag". Equality was only
  # the most obvious spelling of the violation. A BACKWARD version is the
  # dangerous one, and it walks the whole pipeline wearing green: the guard
  # passes, publish_needed? answers false (0.9.0 IS already on RubyGems), phase 2
  # prints the actively-misleading "already live — skip", consumer_bump_action
  # answers :rewrite_pin, and the consumer is rewritten DOWNWARD — a production
  # downgrade, CI-green, QA-green, shipped, with the real commits stranded.
  # Assert the POSITIVE property (did it advance?), never a list of bad spellings.

  test "stranded_gem_work? BLOCKS a BACKWARD version (the silent production downgrade)" do
    assert S.stranded_gem_work?(ahead_commits: ["abc123 engine fix"], version: "0.9.0", tag_version: "0.10.0"),
           "a version BEHIND the last published tag must BLOCK — it would downgrade consumers, " \
           "not publish; the guard asserts strictly-newer, not merely different"
  end

  test "stranded_gem_work? BLOCKS a version that only LOOKS different from the tag" do
    # 0.10 == 0.10.0 under Gem::Version. A string compare calls this a healthy
    # bump; it is the unbumped version wearing a different spelling.
    assert S.stranded_gem_work?(ahead_commits: ["abc123 engine fix"], version: "0.10", tag_version: "0.10.0"),
           "version equality is SEMANTIC (Gem::Version), not textual"
  end

  test "stranded_gem_work? BLOCKS an unparseable version (cannot prove it advanced)" do
    assert S.stranded_gem_work?(ahead_commits: ["abc123 engine fix"], version: "not-a-version", tag_version: "0.10.0"),
           "an unparseable version fails to the SAFE side — it can never prove it advanced"
    assert S.stranded_gem_work?(ahead_commits: ["abc123 engine fix"], version: "0.11.0", tag_version: "garbage"),
           "an unparseable TAG fails safe the same way"
  end

  test "stranded_gem_work? still passes a genuinely forward version, including prereleases" do
    assert_not S.stranded_gem_work?(ahead_commits: ["abc123 fix"], version: "0.10.1", tag_version: "0.10.0")
    assert_not S.stranded_gem_work?(ahead_commits: ["abc123 fix"], version: "1.0.0", tag_version: "0.10.0")
    # a prerelease of the NEXT version is ahead of the tag (Gem::Version orders it so)
    assert_not S.stranded_gem_work?(ahead_commits: ["abc123 fix"], version: "0.11.0.rc1", tag_version: "0.10.0")
    # ...but a prerelease of the SAME version is NOT ahead of the released tag
    assert S.stranded_gem_work?(ahead_commits: ["abc123 fix"], version: "0.10.0.rc1", tag_version: "0.10.0"),
           "0.10.0.rc1 sorts BEFORE 0.10.0 — it has not advanced past the published tag"
  end

  test "stranded_gem_message names the commits, the version_file, and the fix" do
    msg = S.stranded_gem_message("studio-engine",
                                 ahead_commits: ["abc123 engine fix", "def456 second"],
                                 version: "0.10.0", version_file: "lib/studio/version.rb",
                                 tag_version: "0.10.0")
    assert_includes msg, "studio-engine"
    assert_includes msg, "2 commit(s)"
    assert_includes msg, "abc123 engine fix"
    assert_includes msg, "def456 second"
    assert_includes msg, "lib/studio/version.rb"
    assert_includes msg, "STRANDING"
    assert_includes msg, "Bump the version"
    assert_includes msg, "bin/release prepare"
  end

  test "stranded_gem_message samples long commit lists" do
    commits = (1..14).map { |i| "sha#{i} commit #{i}" }
    msg = S.stranded_gem_message("studio-engine", ahead_commits: commits,
                                 version: "0.10.0", version_file: "lib/studio/version.rb",
                                 tag_version: "0.10.0")
    assert_includes msg, "sha10 commit 10"
    assert_not_includes msg, "sha11 commit 11"
    assert_includes msg, "(+4 more)"
  end

  # The message must report the REAL tag and call a downgrade a downgrade. Under
  # the old signature it printed `version` as the tag — for the backward vector
  # that told the operator the tag was v0.9.0 and buried the downgrade entirely.
  test "stranded_gem_message reports the TAG (not the version) and names a downgrade" do
    msg = S.stranded_gem_message("studio-engine", ahead_commits: ["abc123 engine fix"],
                                 version: "0.9.0", version_file: "lib/studio/version.rb",
                                 tag_version: "0.10.0")
    assert_includes msg, "past the last published tag v0.10.0",
                    "the message names the ACTUAL published tag, never the unbumped version_file value"
    assert_includes msg, "DOWNGRADE", "a backward version must be called what it is"
    assert_includes msg, "PAST 0.10.0", "the fix names the floor the bump must clear"
    assert_not_includes msg, "already live",
                        "the skip wording belongs to the equal-version case, not the backward one"
  end

  # --- locked_version / lock_bump_landed? -------------------------------------
  #
  # The regression these pin (rel-20260809-3b8f3d, 2026-08-09): bin/release read
  # `git status --porcelain` after `bundle lock --update` and treated an UNCHANGED
  # tree as proof the lock already carried the new version. A RubyGems index that
  # had not yet propagated produces exactly that same unchanged tree while leaving
  # the OLD version resolved — so the sweep announced 0.31.0 over a 0.30.0 lock.

  # A realistic lock naming the gem at all THREE depths at once. If the parser
  # anchored on the name alone it would happily return "~>" or the wrong line.
  LOCKFILE = <<~LOCK.freeze
    GEM
      remote: https://rubygems.org/
      specs:
        rails (7.2.1)
        studio-engine (0.30.0)
        turbo-rails (2.0.6)
          rails (>= 7.0.0)
          studio-engine (~> 0.30)

    PLATFORMS
      arm64-darwin-24

    DEPENDENCIES
      rails (~> 7.2)
      studio-engine (~> 0.30)
  LOCK

  test "locked_version reads the resolved spec, not a requirement at another depth" do
    assert_equal "0.30.0", S.locked_version(LOCKFILE, "studio-engine"),
                 "the 4-space GEM/specs line is the only resolved version in the file"
    assert_equal "7.2.1", S.locked_version(LOCKFILE, "rails")
  end

  # The INDENT ANCHOR carries this one on its own. Every requirement Bundler
  # actually writes contains an operator and a space (`~> 0.30`), which the
  # `[^()\s]+` capture already refuses — so without this case the anchor is
  # decoration that a later edit could drop with the suite still green (found by
  # mutating the anchor to `^\s*` and watching nothing fail). Here the deeper line
  # is bare-versioned, so ONLY the depth distinguishes it, and it is deliberately
  # ordered BEFORE the real spec so an unanchored parser returns the wrong value
  # rather than merely a lucky one.
  test "locked_version ignores a bare-versioned line at a deeper indent" do
    lock = <<~LOCK
      GEM
        specs:
          some-other-gem (1.0.0)
            studio-engine (0.9.9)
          studio-engine (0.31.0)
    LOCK
    assert_equal "0.31.0", S.locked_version(lock, "studio-engine"),
                 "a 6-space line is another spec's dependency, never the resolution"
  end

  test "locked_version is nil when the lock does not resolve the gem" do
    assert_nil S.locked_version(LOCKFILE, "solana-studio")
    assert_nil S.locked_version("", "studio-engine")
  end

  # The exact live failure: bundle resolved the OLD version because RubyGems had
  # not propagated, the tree therefore did not change, and the old code called
  # that success.
  test "lock_bump_landed? is FALSE when propagation lag left the old version resolved" do
    assert_not S.lock_bump_landed?(LOCKFILE, "studio-engine", "0.31.0"),
               "a lock still resolving 0.30.0 has NOT landed 0.31.0, however clean the diff looks"
  end

  test "lock_bump_landed? is TRUE only when the lock actually resolves the asked-for version" do
    landed = LOCKFILE.sub("studio-engine (0.30.0)", "studio-engine (0.31.0)")
    assert S.lock_bump_landed?(landed, "studio-engine", "0.31.0")
  end

  # A genuine idempotent re-run: the lock was already at the target. This is the
  # case the old message CLAIMED to describe, and it must stay a clean no-op.
  test "lock_bump_landed? is TRUE for a real idempotent re-run" do
    assert S.lock_bump_landed?(LOCKFILE, "studio-engine", "0.30.0")
  end

  test "lock_bump_landed? compares versions semantically, not as strings" do
    padded = LOCKFILE.sub("studio-engine (0.30.0)", "studio-engine (0.30)")
    assert S.lock_bump_landed?(padded, "studio-engine", "0.30.0"),
           "0.30 and 0.30.0 are the same version; Gem::Version owns that judgement"
  end

  test "lock_bump_landed? is FALSE when the gem is absent or the version is blank/garbage" do
    assert_not S.lock_bump_landed?(LOCKFILE, "solana-studio", "0.4.7")
    assert_not S.lock_bump_landed?(LOCKFILE, "studio-engine", "")
    assert_not S.lock_bump_landed?(LOCKFILE, "studio-engine", "not-a-version")
  end

  # --- PLATFORM ROWS ---------------------------------------------------------
  #
  # A native gem gets one spec row PER PLATFORM with the platform inside the
  # parens. The version is everything before the first hyphen — Bundler's own
  # grammar. This was a live defect: the parser returned
  # "1.17.4-aarch64-linux-gnu" and so disagreed with Bundler on 4 gems in this
  # repo's real lockfile. Note `Gem::Version.correct?` cannot police it — it
  # ACCEPTS the suffixed string, reading the hyphen as `.pre.`.
  PLATFORM_LOCK = <<~LOCK.freeze
    GEM
      remote: https://rubygems.org/
      specs:
        ffi (1.17.4)
        ffi (1.17.4-aarch64-linux-gnu)
        ffi (1.17.4-x86_64-darwin)

    DEPENDENCIES
      ffi
  LOCK

  test "locked_version strips the platform suffix from a native gem's spec rows" do
    assert_equal "1.17.4", S.locked_version(PLATFORM_LOCK, "ffi"),
                 "the version is everything before the first hyphen (Bundler's own lockfile grammar)"
    assert S.lock_bump_landed?(PLATFORM_LOCK, "ffi", "1.17.4")
  end

  test "locked_version fails CLOSED when platform rows disagree on the version" do
    conflicting = PLATFORM_LOCK.sub("ffi (1.17.4-x86_64-darwin)", "ffi (1.18.0-x86_64-darwin)")
    assert_nil S.locked_version(conflicting, "ffi"),
               "rows that disagree are not a resolution we can vouch for"
    assert_not S.lock_bump_landed?(conflicting, "ffi", "1.17.4")
  end

  # --- SECTION ANCHORING -----------------------------------------------------
  #
  # PATH and GIT blocks carry their OWN `specs:` at the same four-space indent as
  # GEM's, so indent alone cannot tell a published gem from a path/git-sourced
  # one. The guard's question is "did the version we published TO RUBYGEMS land
  # here?", so a path- or git-sourced consumer must NOT satisfy it. This matters
  # most in repin_consumers, whose whole job is branch-referencing Gemfiles.
  PATH_SOURCED_LOCK = <<~LOCK.freeze
    PATH
      remote: ../studio
      specs:
        studio-engine (0.31.0)

    GEM
      remote: https://rubygems.org/
      specs:
        rails (7.2.1)

    DEPENDENCIES
      studio-engine!
  LOCK

  test "locked_version ignores a PATH-sourced spec — it did not come from RubyGems" do
    assert_nil S.locked_version(PATH_SOURCED_LOCK, "studio-engine"),
               "a path: consumer must not look like a published-gem resolution"
    assert_not S.lock_bump_landed?(PATH_SOURCED_LOCK, "studio-engine", "0.31.0"),
               "the guard asks whether the PUBLISHED version landed; a local path never answers yes"
    assert_equal "7.2.1", S.locked_version(PATH_SOURCED_LOCK, "rails"),
                 "the GEM section in the same file still resolves normally"
  end

  test "locked_version ignores a GIT-sourced spec" do
    git_lock = PATH_SOURCED_LOCK.sub("PATH\n  remote: ../studio", "GIT\n  remote: https://github.com/x/y.git")
    assert_nil S.locked_version(git_lock, "studio-engine")
  end

  # --- path_locked_version: the SELF-BUNDLING read ------------------------------
  #
  # A gem that bundles ITSELF (studio-engine: `PATH / remote: .`) carries its own
  # version in its OWN lockfile and NEVER appears in a GEM section there. That is
  # why the version-allocation commit cannot assert its lockfile through
  # locked_version — it answers nil for the gem it is asking about, so the
  # assertion would pass vacuously and ship a version whose lock contradicts it
  # (fatal under CI's frozen `bundler-cache: true` install).
  SELF_BUNDLED_LOCK = <<~LOCK.freeze
    PATH
      remote: .
      specs:
        studio-engine (0.38.0)
          rails (>= 7.2)

    GEM
      remote: https://rubygems.org/
      specs:
        rails (7.2.1)

    DEPENDENCIES
      studio-engine!
  LOCK

  test "path_locked_version reads the self-bundled spec locked_version cannot see" do
    assert_nil S.locked_version(SELF_BUNDLED_LOCK, "studio-engine"),
               "the GEM-only read is blind here — that blindness is what path_locked_version exists for"
    assert_equal "0.38.0", S.path_locked_version(SELF_BUNDLED_LOCK, "studio-engine")
  end

  test "path_locked_version reads only PATH sections" do
    assert_nil S.path_locked_version(SELF_BUNDLED_LOCK, "rails"),
               "a RubyGems-sourced gem must not answer the path read"
    assert_nil S.path_locked_version("", "studio-engine")
  end

  # The two reads are complements, and the allocation guard tries both so it also
  # covers a gem that does NOT self-bundle.
  test "path_locked_version and locked_version never both answer for one gem" do
    assert_nil S.path_locked_version(LOCKFILE, "studio-engine")
    assert_equal "0.30.0", S.locked_version(LOCKFILE, "studio-engine")
  end

  test "gem_sections keeps only GEM bodies" do
    kept = S.gem_sections(PATH_SOURCED_LOCK)
    assert_includes kept, "rails (7.2.1)"
    assert_not_includes kept, "studio-engine (0.31.0)"
  end
end
