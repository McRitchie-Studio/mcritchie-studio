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

  # --- preflight_offenders: every app checkout must be on a clean `main` ----
  #
  # The pure decision behind bin/release's ship_preflight: ship ff's each app
  # repo's main → frozen SHA, so a checkout left on a pr-NNN branch or with a
  # dirty tree (stale schema.rb) breaks the ff mid-ship. The preflight catches
  # that BEFORE any ff; this is its decision half (the git I/O lives in the CLI).

  def state(repo, branch: "main", dirty_files: [])
    { "repo" => repo, "branch" => branch, "dirty_files" => dirty_files }
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

  # --- preflight_message: the loud, actionable abort text -------------------

  test "preflight_message names each offender, why, and the fix" do
    offenders = S.preflight_offenders([
      state("mcritchie-studio", branch: "pr-161"),
      state("turf-monster", dirty_files: %w[db/schema.rb app/x.rb])
    ])
    msg = S.preflight_message(offenders)
    assert_match(/ship preflight failed/, msg)
    assert_match(/mcritchie-studio: on 'pr-161', not 'main'/, msg)
    assert_match(/turf-monster:.*dirty tree: db\/schema\.rb/, msg)
    assert_match(/re-run `bin\/release ship`/, msg)
  end

  test "preflight_message truncates a long dirty file list" do
    files = (1..9).map { |i| "f#{i}.rb" }
    msg = S.preflight_message(S.preflight_offenders([state("x", dirty_files: files)]))
    assert_match(/\(\+4 more\)/, msg, "only the first 5 files are listed, then a +N more")
  end

  # --- autocleanable?: the release-identical dirty-primary auto-clean decision ---
  #
  # feedback_ship_preflight_dirty_primary: a dirty ON-MAIN primary whose dirt is ALL
  # already on origin/release is redundant merge noise — SAFE to `git reset --hard
  # origin/main`. Anything not provably-safe stays BLOCKING (refuse, never discard
  # local work). The CLI gathers the facts (git I/O); this is the pure verdict.

  # A fully-safe (auto-cleanable) offender: on main, facts gathered, main behind
  # release, dirty, and NOTHING unreconciled.
  def cleanable_offender(overrides = {})
    {
      "repo" => "mcritchie-studio", "on_main" => true, "reconcile_checked" => true,
      "main_ancestor_of_release" => true, "dirty_files" => ["app/x.rb"], "unreconciled_files" => []
    }.merge(overrides)
  end

  test "autocleanable? is true for a dirty on-main primary whose dirt is all on release" do
    assert S.autocleanable?(cleanable_offender)
  end

  test "autocleanable? is false for an off-main checkout (a branch drift is never auto-cleaned)" do
    assert_not S.autocleanable?(cleanable_offender("on_main" => false))
  end

  test "autocleanable? is false when the reconciliation facts were never gathered (default refuse)" do
    # A stubbed / un-reconciled offender lacks reconcile_checked → REFUSE, never a
    # blind reset just because unreconciled_files happens to be absent/empty.
    offender = { "repo" => "x", "on_main" => true, "dirty_files" => ["a.rb"] }
    assert_not S.autocleanable?(offender)
  end

  test "autocleanable? is false when origin/main is NOT an ancestor of origin/release" do
    assert_not S.autocleanable?(cleanable_offender("main_ancestor_of_release" => false))
  end

  test "autocleanable? is false when any dirty file is not on origin/release (local work)" do
    assert_not S.autocleanable?(cleanable_offender("unreconciled_files" => ["app/local_only.rb"]))
  end

  test "autocleanable? is false when there are no dirty files to clean" do
    assert_not S.autocleanable?(cleanable_offender("dirty_files" => [], "unreconciled_files" => []))
  end

  test "autocleanable? accepts symbol-keyed facts and string boolean flags" do
    sym = { repo: "x", on_main: true, reconcile_checked: true,
            main_ancestor_of_release: true, dirty_files: ["a.rb"], unreconciled_files: [] }
    assert S.autocleanable?(sym)
    # A JSON round-trip could stringify the booleans — still honored.
    assert S.autocleanable?(cleanable_offender("main_ancestor_of_release" => "true"))
    assert_not S.autocleanable?(cleanable_offender("reconcile_checked" => "false"))
  end

  test "partition_autocleanable splits the safe resets from the blocking offenders" do
    safe = cleanable_offender("repo" => "mcritchie-studio")
    blocked_dirty = cleanable_offender("repo" => "turf-monster", "unreconciled_files" => ["a.rb"])
    blocked_branch = cleanable_offender("repo" => "rolio", "on_main" => false)

    cleanable, blocking = S.partition_autocleanable([safe, blocked_dirty, blocked_branch])
    assert_equal %w[mcritchie-studio], cleanable.map { |o| o["repo"] }
    assert_equal %w[turf-monster rolio], blocking.map { |o| o["repo"] }
  end
end
