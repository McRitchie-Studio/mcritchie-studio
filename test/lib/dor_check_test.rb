# frozen_string_literal: true

# Standalone test for bin/dor-check (no Rails needed — it shells out to the
# script with --file fixtures). Run directly:
#   ruby -Itest test/lib/dor_check_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"

class DorCheckTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)

  # Runs dor-check against an in-memory devops payload, returns [output, exitcode].
  def check(devops, *args)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "task.json")
      File.write(path, JSON.generate(
        "slug" => "task-test", "title" => "T", "metadata" => { "devops" => devops }
      ))
      # Capture STDOUT only. dor-check prints its verdict (text and --json) to
      # stdout via puts; when this test runs inside `bin/rails test`, the
      # subprocess inherits bundler's env and emits rubygems "already
      # initialized constant" warnings to STDERR — merging them (2>&1) would
      # corrupt the JSON parse. Discarding stderr keeps the verdict clean.
      with_default_suite_evidence do
        out = IO.popen("#{BIN} --file #{path} #{args.join(' ')} 2>/dev/null", &:read)
        [out, $?.exitstatus]
      end
    end
  end

  # The merge gate now also demands fingerprint-bound FULL-suite + rubocop evidence
  # for a shaped feature (see "--- FULL-suite gate" tests below). Default it to
  # fresh-green so the EXISTING shape/tier/post-deploy tests stay focused on THEIR
  # subject. A test that exercises the full-suite gate itself sets
  # DOR_CHECK_SUITE_EVIDENCE — to a token (ok|missing|stale|tests_stale|
  # rubocop_stale|unverifiable), or to "" to take the REAL fingerprint path — and
  # then this default steps aside (the key is already present on entry).
  def with_default_suite_evidence
    had = ENV.key?("DOR_CHECK_SUITE_EVIDENCE")
    ENV["DOR_CHECK_SUITE_EVIDENCE"] = "ok" unless had
    yield
  ensure
    ENV.delete("DOR_CHECK_SUITE_EVIDENCE") unless had
  end

  # Inject a deterministic branch diff for the duration of a check. The subprocess
  # inherits this process's ENV, so setting DOR_CHECK_CHANGED_FILES here drives the
  # script's code-diff detection without shelling out to git. `files` is newline/
  # comma separated; "" means "no diff". Any chore/cleanup/docs case must wrap its
  # check, since the exemption now depends on whether the branch ships code.
  def with_changed_files(files)
    had = ENV.key?("DOR_CHECK_CHANGED_FILES")
    prev = ENV["DOR_CHECK_CHANGED_FILES"]
    ENV["DOR_CHECK_CHANGED_FILES"] = files
    yield
  ensure
    had ? (ENV["DOR_CHECK_CHANGED_FILES"] = prev) : ENV.delete("DOR_CHECK_CHANGED_FILES")
  end

  # Temporarily set/unset a batch of ENV vars (nil value = unset), restoring the
  # prior state afterward. Used to point the script's REAL git detection at a temp
  # repo (DOR_CHECK_DIFF_ROOT/_BASE) while making sure the DOR_CHECK_CHANGED_FILES
  # injection is OFF — so these tests exercise the actual working-tree diff path.
  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, [ENV.key?(k), ENV[k]]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, (had, val)| had ? ENV[k] = val : ENV.delete(k) }
  end

  # Build a throwaway git repo so the script's real changed_files git path can be
  # exercised deterministically (no DOR_CHECK_CHANGED_FILES injection). Files are
  # relative paths placed in one of three working-tree states:
  #   staged    — new file, git add'd (git diff --cached)
  #   unstaged  — committed baseline, then modified (git diff)
  #   untracked — new file, never added (git ls-files --others)
  # The base is HEAD, so the committed view (base...HEAD) is empty — mirroring the
  # pre-commit SOP case where HEAD carries no feature commit yet. Yields the repo
  # dir; the block runs dor-check via with_env(DOR_CHECK_DIFF_ROOT => dir, ...).
  def with_git_repo(staged: [], unstaged: [], untracked: [])
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("commit -q --allow-empty -m init")

      # Commit a baseline for the files that should read as "unstaged" edits.
      unless unstaged.empty?
        unstaged.each { |rel| write.call(rel, "base\n") }
        git.call("add -A")
        git.call("commit -q -m baseline")
      end
      # Stage the new files explicitly so the unstaged edits below stay unstaged.
      staged.each do |rel|
        write.call(rel, "new\n")
        git.call("add -- #{rel}")
      end
      # Now apply the unstaged working-tree edits (after staging, so they remain unstaged).
      unstaged.each { |rel| write.call(rel, "changed\n") }
      # Untracked new files (never added).
      untracked.each { |rel| write.call(rel, "new\n") }

      yield dir
    end
  end

  # Run dor-check against a temp repo's real working tree (injection OFF).
  def check_against(dir, devops, *args)
    with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD", "DOR_CHECK_CHANGED_FILES" => nil) do
      check(devops, *args)
    end
  end

  # Build a throwaway repo modeling the persistent-`release` topology that drives
  # the false-positive bug: origin/main sits at a baseline, origin/release runs
  # AHEAD of it by a real `release_code` commit (merged-but-unshipped work), and
  # HEAD is a feature branch cut off `release` carrying `branch_files` (committed,
  # so the working tree is CLEAN — only the committed-diff view is exercised). The
  # remote-tracking refs are forged with update-ref (no real remote needed). With
  # the release-aware default base, `release_code` must NOT show up in this
  # branch's diff; the old origin/main default wrongly dragged it in.
  def with_release_ahead_repo(release_code: ["app/models/release_thing.rb"], branch_files: [])
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      sha = -> { `git -C #{dir} rev-parse HEAD`.strip }
      write = lambda do |rel, body|
        full = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, body)
      end
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")

      # origin/main baseline.
      write.call("README.md", "base\n")
      git.call("add -A")
      git.call("commit -q -m main-baseline")
      git.call("update-ref refs/remotes/origin/main #{sha.call}")

      # origin/release: AHEAD of main by a real code commit (merged-but-unshipped).
      release_code.each { |rel| write.call(rel, "shipped to release\n") }
      git.call("add -A")
      git.call("commit -q -m release-only-code")
      git.call("update-ref refs/remotes/origin/release #{sha.call}")

      # Feature branch cut off release: its own committed change, clean tree.
      unless branch_files.empty?
        branch_files.each { |rel| write.call(rel, "feature change\n") }
        git.call("add -A")
        git.call("commit -q -m feature-change")
      end

      yield dir
    end
  end

  # Resolve the committed-diff base the script would use for `dir`, honoring the
  # same DOR_CHECK_DIFF_ROOT/_BASE seams. Uses the script's --diff-base resolver
  # so the unit tests exercise the real resolution (release-aware default + env
  # override), not a reimplementation.
  def resolved_base(dir, env = {})
    base = nil
    with_env({ "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => nil, "DOR_CHECK_CHANGED_FILES" => nil }.merge(env)) do
      base = IO.popen("#{BIN} --diff-base 2>/dev/null", &:read).strip
    end
    base
  end

  # --- regression: release-aware committed-diff base (the headline bug) -------
  # A branch cut off `release` (which runs AHEAD of `main`) used to diff against
  # origin/main, dragging in everyone else's already-merged-to-release code → a
  # docs-only chore got a FALSE code-diff flag. The fix defaults the committed
  # base to origin/release when it exists. This test FAILS on the old default.

  def test_release_cut_docs_branch_not_false_flagged_as_code
    with_release_ahead_repo(
      release_code: ["app/models/release_thing.rb"],
      branch_files: ["docs/agents/sop.md"]
    ) do |dir|
      # No DOR_CHECK_DIFF_BASE override → exercises the release-aware default.
      with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => nil, "DOR_CHECK_CHANGED_FILES" => nil) do
        out, code = check("kind" => "chore")
        assert_equal 0, code, out
        assert_match(/DoR n\/a/, out)
        assert_match(/non-code task \(kind: chore\)/, out)
        refute_match(%r{app/models/release_thing\.rb}, out)
      end
    end
  end

  # --- [unit] default_diff_base resolution -----------------------------------

  def test_default_diff_base_prefers_origin_release_when_present
    with_release_ahead_repo { |dir| assert_equal "origin/release", resolved_base(dir) }
  end

  def test_default_diff_base_falls_back_to_origin_main_without_release
    # Plain repo: no origin/release forged → falls back to origin/main.
    with_git_repo { |dir| assert_equal "origin/main", resolved_base(dir) }
  end

  def test_diff_base_env_override_wins_over_release_default
    # DOR_CHECK_DIFF_BASE stays authoritative even when origin/release exists.
    with_release_ahead_repo do |dir|
      assert_equal "origin/main", resolved_base(dir, "DOR_CHECK_DIFF_BASE" => "origin/main")
    end
  end

  # --- [integration] end-to-end gate over the release-ahead topology ---------

  def test_e2e_release_cut_docs_branch_passes_merge_gate
    with_release_ahead_repo(branch_files: ["docs/agents/sop.md"]) do |dir|
      with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => nil, "DOR_CHECK_CHANGED_FILES" => nil) do
        out, code = check("kind" => "chore")
        assert_equal 0, code, out
        assert_match(/DoR-to-Merge n\/a/, out)
        assert_match(/ready to advance submitted → reviewed/, out)
      end
    end
  end

  def test_e2e_release_cut_code_branch_still_gated
    # Don't over-correct into under-gating: a release-cut branch that itself adds
    # app/ code is STILL gated — but only for its OWN code, not release's.
    with_release_ahead_repo(branch_files: ["app/services/charger.rb"]) do |dir|
      with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => nil, "DOR_CHECK_CHANGED_FILES" => nil) do
        out, code = check("kind" => "chore")
        assert_equal 1, code, out
        assert_match(/ships a code diff/, out)
        assert_match(%r{app/services/charger\.rb}, out)
        refute_match(%r{app/models/release_thing\.rb}, out)
      end
    end
  end

  def test_passes_when_shape_contract_is_satisfied
    # Inject a plain code-file diff so this asserts the SHAPE-CONTRACT path
    # deterministically, independent of what this branch's real working tree
    # happens to touch (e.g. a migration would trip the post_deploy_cmd rule).
    out, code = with_changed_files("app/models/agent.rb") do
      check(
        "shape" => "backend",
        "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["devops"],
        "acceptance" => ["gate works"],
        "test_plan" => ["unit", "integration"],
        "checks_run" => ["[unit] x", "[integration] y"]
      )
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    assert_match(/submitted → reviewed/, out)
  end

  def test_build_gate_passes_on_spec_without_test_tiers
    # DoR-to-Build only needs a complete spec — no test tiers yet (no code).
    out, code = check(
      { "shape" => "backend", "repositories" => ["m"], "risk_tags" => ["x"],
        "acceptance" => ["a"], "test_plan" => ["unit"], "checks_run" => [] },
      "--gate", "build"
    )
    assert_equal 0, code, out
    assert_match(/DoR-to-Build met/, out)
    assert_match(/designed → building/, out)
  end

  def test_build_gate_still_requires_the_spec
    out, code = check({ "shape" => "backend" }, "--gate", "build")
    assert_equal 1, code, out
    assert_match(/acceptance/, out)
  end

  def test_fails_and_lists_missing_tiers_and_metadata
    out, code = check(
      "shape" => "ui+db",
      "repositories" => ["turf-monster"],
      "risk_tags" => ["ui"],
      "acceptance" => ["x"],
      "test_plan" => ["unit"],
      "checks_run" => ["[unit] x"] # missing component/integration/e2e + local_url
    )
    assert_equal 1, code, out
    assert_match(/local_url/, out)
    assert_match(/component/, out)
  end

  def test_fails_on_missing_shape
    out, code = check("repositories" => ["m"])
    assert_equal 1, code
    assert_match(/shape is not set/, out)
  end

  def test_fails_on_unknown_shape
    out, code = check("shape" => "bogus")
    assert_equal 1, code
    assert_match(/unknown shape/, out)
  end

  def test_json_verdict_is_machine_readable
    out, code = with_changed_files("app/models/agent.rb") do
      check(
        { "shape" => "backend", "repositories" => ["m"], "risk_tags" => ["x"],
          "acceptance" => ["a"], "test_plan" => ["unit"],
          "checks_run" => ["[unit] x", "[integration] y"] },
        "--json"
      )
    end
    assert_equal 0, code, out
    verdict = JSON.parse(out)
    assert verdict["ready"]
    assert_equal "backend", verdict["shape"]
    assert_empty verdict["missing_tiers"]
  end

  def test_tier_tag_accepts_colon_and_spacing
    out, code = with_changed_files("app/models/agent.rb") do
      check(
        "shape" => "backend",
        "repositories" => ["m"], "risk_tags" => ["x"], "acceptance" => ["a"],
        "test_plan" => ["unit"],
        "checks_run" => ["[ unit : ] bin/rails test", "[integration] flow"]
      )
    end
    assert_equal 0, code, out
  end

  def test_chore_kind_is_exempt_without_a_shape
    out, code = with_changed_files("") { check("kind" => "chore") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
    assert_match(/non-code task \(kind: chore\)/, out)
  end

  def test_cleanup_kind_is_exempt_without_a_shape
    out, code = with_changed_files("") { check("kind" => "cleanup") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
  end

  def test_chore_exemption_in_json_verdict
    out, code = with_changed_files("") { check({ "kind" => "chore" }, "--json") }
    assert_equal 0, code, out
    verdict = JSON.parse(out)
    assert verdict["ready"]
    assert verdict["exempt"]
    assert_equal "chore", verdict["kind"]
  end

  # --- no size exemption: a chore that ships code gets gated like a feature ---

  def test_doc_only_chore_stays_exempt
    out, code = with_changed_files("docs/agents/foo.md\nREADME.md") { check("kind" => "chore") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
  end

  def test_chore_with_a_code_diff_and_no_shape_is_refused
    out, code = with_changed_files("bin/dor-check\napp/models/task.rb") { check("kind" => "chore") }
    assert_equal 1, code, out
    assert_match(/ships a code diff/, out)
    assert_match(/bin\/dor-check/, out)
    assert_match(/set devops\.shape/, out)
  end

  def test_chore_with_a_code_diff_passes_when_the_shape_contract_is_met
    out, code = with_changed_files("bin/dor-check") do
      check(
        "kind" => "chore", "shape" => "backend", "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["tooling"], "acceptance" => ["gate fires on code chores"],
        "test_plan" => ["unit", "integration"],
        "checks_run" => ["[unit] x", "[integration] y"]
      )
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
  end

  def test_chore_with_a_code_diff_still_needs_the_test_tiers
    out, code = with_changed_files("lib/foo.rb") do
      check(
        "kind" => "chore", "shape" => "backend", "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["tooling"], "acceptance" => ["gate fires"],
        "test_plan" => ["unit", "integration"], "checks_run" => ["[unit] x"]
      )
    end
    assert_equal 1, code, out
    assert_match(/integration/, out)
  end

  def test_code_diff_chore_refusal_in_json_verdict
    out, code = with_changed_files("config/routes.rb") { check({ "kind" => "chore" }, "--json") }
    assert_equal 1, code, out
    verdict = JSON.parse(out)
    refute verdict["ready"]
    assert(verdict["errors"].any? { |e| e =~ /ships a code diff/ })
  end

  def test_missing_shape_still_fails_when_kind_is_not_exempt
    out, code = check("kind" => "feature", "repositories" => ["m"])
    assert_equal 1, code, out
    assert_match(/shape is not set/, out)
  end

  # --- [unit] real git working-tree detection --------------------------------
  # The injection tests above prove the GATE logic; these prove the DETECTION
  # itself sees uncommitted code (the bug: it used to read only base...HEAD, so a
  # code-producing chore run pre-commit — the SOP order — was wrongly exempted).

  def test_detects_staged_code_file_pre_commit
    with_git_repo(staged: ["app/models/widget.rb"]) do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 1, code, out
      assert_match(/ships a code diff/, out)
      assert_match(%r{app/models/widget\.rb}, out)
    end
  end

  def test_detects_unstaged_code_file_pre_commit
    with_git_repo(unstaged: ["lib/foo.rb"]) do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 1, code, out
      assert_match(/ships a code diff/, out)
      assert_match(%r{lib/foo\.rb}, out)
    end
  end

  def test_detects_untracked_code_file_pre_commit
    with_git_repo(untracked: ["bin/new-tool"]) do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 1, code, out
      assert_match(/ships a code diff/, out)
      assert_match(%r{bin/new-tool}, out)
    end
  end

  def test_doc_only_working_tree_yields_empty_code_set
    # docs/ + *.md across all three states — no CODE_PATH_PREFIXES → stays exempt.
    with_git_repo(staged: ["README.md"], unstaged: ["docs/guide.md"], untracked: ["NOTES.md"]) do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 0, code, out
      assert_match(/DoR n\/a/, out)
      assert_match(/non-code task \(kind: chore\)/, out)
    end
  end

  def test_clean_working_tree_keeps_chore_exempt
    with_git_repo do |dir| # nothing changed
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 0, code, out
      assert_match(/DoR n\/a/, out)
    end
  end

  def test_changed_files_injection_overrides_real_git
    # A real code file is present, but DOR_CHECK_CHANGED_FILES="" must win → exempt.
    with_git_repo(untracked: ["app/models/widget.rb"]) do |dir|
      with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD", "DOR_CHECK_CHANGED_FILES" => "") do
        out, code = check("kind" => "chore")
        assert_equal 0, code, out
        assert_match(/DoR n\/a/, out)
      end
    end
  end

  # --- [integration] end-to-end gate over real git state ---------------------

  def test_e2e_code_producing_chore_fails_merge_gate
    # The headline regression: a kind:chore with an uncommitted code diff must be
    # GATED (demand shape + tiers), not waved through as a non-code task.
    with_git_repo(untracked: ["app/services/charger.rb"]) do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 1, code, out
      assert_match(/DoR-to-Merge NOT met/, out)
      assert_match(/set devops\.shape/, out)
      refute_match(/DoR n\/a/, out)
    end
  end

  def test_e2e_doc_only_chore_passes_merge_gate
    with_git_repo(untracked: ["docs/agents/whatever.md"]) do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 0, code, out
      assert_match(/DoR-to-Merge n\/a/, out)
      assert_match(/ready to advance submitted → reviewed/, out)
    end
  end

  def test_e2e_code_chore_passes_once_shape_and_tiers_supplied
    # Same code diff, but now the chore carries the full backend contract → PASS.
    with_git_repo(untracked: ["app/services/charger.rb"]) do |dir|
      out, code = check_against(
        dir,
        "kind" => "chore", "shape" => "backend", "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["tooling"], "acceptance" => ["gate fires on code chores"],
        "test_plan" => ["unit", "integration"],
        "checks_run" => ["[unit] x", "[integration] y"]
      )
      assert_equal 0, code, out
      assert_match(/DoR-to-Merge met/, out)
    end
  end

  # --- post-deploy nudge: seed / data-migration diffs must declare a command ---
  # A diff under db/seeds or db/migrate/ should carry devops.post_deploy_cmd so
  # the conductor runs the seed/backfill on ship — these tests use the injection
  # seam (DOR_CHECK_CHANGED_FILES) to drive the diff deterministically. The
  # otherwise-complete backend contract isolates the nudge as the sole failure.

  BACKEND_CONTRACT = {
    "shape" => "backend", "repositories" => ["mcritchie-studio"],
    "risk_tags" => ["migration"], "acceptance" => ["adds the table"],
    "test_plan" => ["unit", "integration"],
    "checks_run" => ["[unit] x", "[integration] y"]
  }.freeze

  def test_migration_diff_without_post_deploy_cmd_is_gated
    out, code = with_changed_files("db/migrate/20260623120000_add_widgets.rb") do
      check(BACKEND_CONTRACT)
    end
    assert_equal 1, code, out
    assert_match(/post_deploy_cmd is blank/, out)
    assert_match(%r{db/migrate/20260623120000_add_widgets\.rb}, out)
    assert_match(/--post-deploy-cmd/, out)
  end

  def test_seed_diff_without_post_deploy_cmd_is_gated
    # db/seeds.rb (the file) and db/seeds/*.rb (the dir) both trip the nudge.
    out, code = with_changed_files("db/seeds/pokemon.rb") { check(BACKEND_CONTRACT) }
    assert_equal 1, code, out
    assert_match(/post_deploy_cmd is blank/, out)
    assert_match(%r{db/seeds/pokemon\.rb}, out)
  end

  def test_seeds_rb_file_trips_the_nudge
    out, code = with_changed_files("db/seeds.rb") { check(BACKEND_CONTRACT) }
    assert_equal 1, code, out
    assert_match(/post_deploy_cmd is blank/, out)
  end

  def test_migration_diff_passes_when_post_deploy_cmd_declared
    out, code = with_changed_files("db/migrate/20260623120000_add_widgets.rb") do
      check(BACKEND_CONTRACT.merge("post_deploy_cmd" => "bin/rails pokemon:seed"))
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
  end

  def test_explicit_none_acknowledges_a_schema_only_migration
    # The escape hatch: a schema-only migration the release phase auto-runs needs
    # no command, but the author must DECLARE that decision ("none"), not omit it.
    out, code = with_changed_files("db/migrate/20260623120000_add_widgets.rb") do
      check(BACKEND_CONTRACT.merge("post_deploy_cmd" => "none"))
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
  end

  def test_non_data_diff_is_unaffected_by_the_nudge
    # A code diff that touches neither seeds nor migrations never asks for a cmd.
    out, code = with_changed_files("app/models/widget.rb\nlib/foo.rb") do
      check(BACKEND_CONTRACT)
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
  end

  def test_schema_rb_alone_does_not_trip_the_nudge
    # db/schema.rb is under db/ but not db/migrate/ or db/seeds — a bare schema
    # touch (no migration file) isn't a data change the nudge cares about.
    out, code = with_changed_files("db/schema.rb") { check(BACKEND_CONTRACT) }
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
  end

  def test_build_gate_skips_the_post_deploy_nudge
    # post_deploy_cmd is a build artifact (known once the migration exists), so
    # the spec-complete build gate never asks for it — even with a migration diff.
    out, code = with_changed_files("db/migrate/20260623120000_add_widgets.rb") do
      check(
        { "shape" => "backend", "repositories" => ["m"], "risk_tags" => ["migration"],
          "acceptance" => ["adds table"], "test_plan" => ["unit"], "checks_run" => [] },
        "--gate", "build"
      )
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Build met/, out)
  end

  def test_post_deploy_nudge_surfaces_in_json_verdict
    out, code = with_changed_files("db/migrate/20260623120000_add_widgets.rb") do
      check(BACKEND_CONTRACT, "--json")
    end
    assert_equal 1, code, out
    verdict = JSON.parse(out)
    refute verdict["ready"]
    assert(verdict["errors"].any? { |e| e =~ /post_deploy_cmd is blank/ })
  end

  def test_code_chore_adding_a_migration_demands_both_shape_and_post_deploy
    # A chore whose diff is ONLY a migration is gated twice: it ships code (db/ is
    # a code prefix → demand a shape) AND it's a data change (→ demand a command).
    out, code = with_changed_files("db/migrate/20260623120000_add_widgets.rb") do
      check("kind" => "chore")
    end
    assert_equal 1, code, out
    assert_match(/ships a code diff/, out)
    assert_match(/post_deploy_cmd is blank/, out)
  end

  # --- [integration] real git working-tree detection of a migration diff -------

  def test_e2e_real_migration_diff_without_command_fails_merge_gate
    with_git_repo(untracked: ["db/migrate/20260623120000_add_widgets.rb"]) do |dir|
      out, code = check_against(dir, BACKEND_CONTRACT)
      assert_equal 1, code, out
      assert_match(/DoR-to-Merge NOT met/, out)
      assert_match(/post_deploy_cmd is blank/, out)
    end
  end

  def test_e2e_real_migration_diff_passes_with_command
    # A NARROW dedicated rake task (not a bare db:seed — see the safety gate below).
    with_git_repo(untracked: ["db/migrate/20260623120000_add_widgets.rb"]) do |dir|
      out, code = check_against(dir, BACKEND_CONTRACT.merge("post_deploy_cmd" => "bin/rails widgets:backfill"))
      assert_equal 0, code, out
      assert_match(/DoR-to-Merge met/, out)
    end
  end

  # --- post-deploy SAFETY gate: reject a bare full-suite seed command ----------
  # bin/release runs devops.post_deploy_cmd VERBATIM against PRODUCTION. A bare
  # db:seed loads db/seeds.rb → EVERY db/seeds/*.rb (demo data + any non-idempotent
  # file), so it's rejected; a NARROW scoped-runner / dedicated-rake command is
  # required. Real near-miss: merge-docs-reviewer-into-alex shipped 'bin/rails
  # db:seed'. A non-data code diff (app/models) isolates the safety gate as the
  # sole failure (no post-deploy NUDGE, which only fires on db/seeds|db/migrate).

  REJECTED_POST_DEPLOY_CMDS = [
    "bin/rails db:seed",
    "rails db:seed",
    "bundle exec rails db:seed",
    "bin/rails db:seed:replant",
    "rake db:seed",
    "bundle exec rails db:seed RAILS_ENV=production"
  ].freeze

  ACCEPTED_POST_DEPLOY_CMDS = [
    "rails runner 'load Rails.root.join(\"db/seeds/54_demo.rb\").to_s'",
    "bin/rails runner 'load Rails.root.join(\"db/seeds/54_demo.rb\").to_s'",
    "bin/rails pokemon:seed",
    "bin/rails pokemon:resync_mascots",
    "bin/rails db:migrate",
    "none"
  ].freeze

  def test_bare_full_suite_seed_commands_are_rejected
    REJECTED_POST_DEPLOY_CMDS.each do |cmd|
      out, code = with_changed_files("app/models/agent.rb") do
        check(BACKEND_CONTRACT.merge("post_deploy_cmd" => cmd))
      end
      assert_equal 1, code, "expected REJECT for #{cmd.inspect}\n#{out}"
      assert_match(/bare full-suite seed/, out, "why-message missing for #{cmd.inspect}")
      assert_match(/PRODUCTION/, out, "prod-safety rationale missing for #{cmd.inspect}")
      assert_match(/rails runner|dedicated/, out, "narrow pattern missing for #{cmd.inspect}")
    end
  end

  def test_narrow_post_deploy_commands_are_accepted
    ACCEPTED_POST_DEPLOY_CMDS.each do |cmd|
      out, code = with_changed_files("app/models/agent.rb") do
        check(BACKEND_CONTRACT.merge("post_deploy_cmd" => cmd))
      end
      assert_equal 0, code, "expected ACCEPT for #{cmd.inspect}\n#{out}"
      assert_match(/DoR-to-Merge met/, out, cmd)
    end
  end

  def test_blank_post_deploy_cmd_is_not_gated
    # No post_deploy_cmd at all → the safety gate is silent (non-data diff, so the
    # NUDGE doesn't fire either) → the contract passes.
    out, code = with_changed_files("app/models/agent.rb") { check(BACKEND_CONTRACT) }
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    refute_match(/bare full-suite seed/, out)
  end

  def test_seed_diff_with_bare_seed_command_is_rejected_by_safety_not_nudge
    # The command IS present (so the NUDGE is satisfied) but it's the dangerous
    # bare seed — the SAFETY gate is the failure, not the blank-command nudge.
    out, code = with_changed_files("db/seeds/54_demo.rb") do
      check(BACKEND_CONTRACT.merge("post_deploy_cmd" => "bin/rails db:seed"))
    end
    assert_equal 1, code, out
    assert_match(/bare full-suite seed/, out)
    refute_match(/post_deploy_cmd is blank/, out)
  end

  def test_build_gate_also_rejects_a_bare_seed_command
    # The value is dangerous regardless of gate, so the build gate rejects it too.
    out, code = check(
      { "shape" => "backend", "repositories" => ["m"], "risk_tags" => ["x"],
        "acceptance" => ["a"], "test_plan" => ["unit"], "checks_run" => [],
        "post_deploy_cmd" => "bin/rails db:seed" },
      "--gate", "build"
    )
    assert_equal 1, code, out
    assert_match(/bare full-suite seed/, out)
  end

  def test_bare_seed_command_surfaces_in_json_verdict
    out, code = with_changed_files("app/models/agent.rb") do
      check(BACKEND_CONTRACT.merge("post_deploy_cmd" => "bundle exec rails db:seed"), "--json")
    end
    assert_equal 1, code, out
    verdict = JSON.parse(out)
    refute verdict["ready"]
    assert(verdict["errors"].any? { |e| e =~ /bare full-suite seed/ })
  end

  # --- [integration] real git working-tree, bad vs good post_deploy_cmd --------

  def test_e2e_migration_diff_rejects_bare_seed_command
    with_git_repo(untracked: ["db/migrate/20260623120000_add_widgets.rb"]) do |dir|
      out, code = check_against(dir, BACKEND_CONTRACT.merge("post_deploy_cmd" => "bin/rails db:seed"))
      assert_equal 1, code, out
      assert_match(/DoR-to-Merge NOT met/, out)
      assert_match(/bare full-suite seed/, out)
    end
  end

  def test_e2e_migration_diff_accepts_scoped_runner_command
    with_git_repo(untracked: ["db/migrate/20260623120000_add_widgets.rb"]) do |dir|
      cmd = "rails runner 'load Rails.root.join(\"db/seeds/54_demo.rb\").to_s'"
      out, code = check_against(dir, BACKEND_CONTRACT.merge("post_deploy_cmd" => cmd))
      assert_equal 0, code, out
      assert_match(/DoR-to-Merge met/, out)
    end
  end

  # --- [unit] FULL-suite gate: fingerprint-bound evidence required at merge ------
  # The headline retro fix (lines 54 + 58): the dor_tiers tags prove the agent
  # WROTE unit/integration, but a tag is free text — running only the touched FILES
  # satisfies it. The merge gate ALSO demands FRESH full-suite + full-rubocop
  # evidence (bin/full-suite-check records it). These unit tests drive the verdict
  # via the DOR_CHECK_SUITE_EVIDENCE seam; the [integration] block below exercises
  # the REAL git fingerprint. The contract is otherwise complete so the suite gate
  # is the sole variable.
  SUITE_CONTRACT = {
    "shape" => "backend", "repositories" => ["mcritchie-studio"],
    "risk_tags" => ["devops"], "acceptance" => ["enforce the full suite"],
    "test_plan" => ["unit", "integration"],
    "checks_run" => ["[unit] x", "[integration] y"]
  }.freeze

  # Run check with the suite gate set to a specific state (token or "" for real).
  def check_suite(devops, evidence, *args)
    with_env("DOR_CHECK_SUITE_EVIDENCE" => evidence) { check(devops, *args) }
  end

  def test_full_suite_evidence_missing_refuses_merge_gate
    # The touched-files-only PR: [unit]/[integration] tagged, but the FULL suite +
    # rubocop were never certified → REFUSED. This is the whole point of the gate.
    out, code = check_suite(SUITE_CONTRACT, "missing")
    assert_equal 1, code, out
    assert_match(/FULL suite \+ FULL rubocop are not certified/, out)
    assert_match(/full-suite: MISSING/, out)
    assert_match(/rubocop: MISSING/, out)
    assert_match(%r{bin/full-suite-check}, out)
  end

  def test_full_suite_evidence_fresh_passes_merge_gate
    out, code = check_suite(SUITE_CONTRACT, "ok")
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
  end

  def test_full_suite_evidence_stale_refuses
    # Certified, then the code changed → STALE → REFUSED (can't certify a subset
    # and keep editing).
    out, code = check_suite(SUITE_CONTRACT, "stale")
    assert_equal 1, code, out
    assert_match(/full-suite: STALE/, out)
    assert_match(/rubocop: STALE/, out)
  end

  def test_full_suite_rubocop_lane_failure_refuses
    # The "fails full rubocop" outcome: tests certified, lint not → REFUSED.
    out, code = check_suite(SUITE_CONTRACT, "rubocop_stale")
    assert_equal 1, code, out
    assert_match(/rubocop: STALE/, out)
    refute_match(/full-suite: (STALE|MISSING)/, out)
  end

  def test_full_suite_unverifiable_refuses
    # No git fingerprint computable → the gate REFUSES rather than waving through
    # what it cannot confirm.
    out, code = check_suite(SUITE_CONTRACT, "unverifiable")
    assert_equal 1, code, out
    assert_match(/unverifiable/, out)
  end

  def test_full_suite_bypass_record_passes_even_with_no_evidence
    # The escape hatch is a RECORD (like post_deploy "none"): a reasoned
    # [full-suite-bypass] line passes the gate even when evidence is MISSING — but
    # it's flagged LOUDLY in the verdict, never silent.
    devops = SUITE_CONTRACT.merge(
      "checks_run" => SUITE_CONTRACT["checks_run"] + ["[full-suite-bypass] pre-existing mailer-host failure, tracked in task-x"]
    )
    out, code = check_suite(devops, "missing")
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    assert_match(/FULL-SUITE GATE BYPASSED: pre-existing mailer-host failure/, out)
  end

  def test_full_suite_bypass_needs_a_reason
    # A bare [full-suite-bypass] with no reason is NOT honored — the hatch forces a
    # conscious, recorded justification.
    devops = SUITE_CONTRACT.merge(
      "checks_run" => SUITE_CONTRACT["checks_run"] + ["[full-suite-bypass]"]
    )
    out, code = check_suite(devops, "missing")
    assert_equal 1, code, out
    assert_match(/not certified/, out)
  end

  def test_full_suite_gate_skipped_on_build_gate
    # No code yet at design time → the build gate never asks for suite evidence.
    out, code = check_suite(
      { "shape" => "backend", "repositories" => ["m"], "risk_tags" => ["x"],
        "acceptance" => ["a"], "test_plan" => ["unit"], "checks_run" => [] },
      "missing", "--gate", "build"
    )
    assert_equal 0, code, out
    assert_match(/DoR-to-Build met/, out)
  end

  def test_full_suite_gate_not_required_for_exempt_no_code_chore
    # An exempt no-code chore short-circuits before the suite gate — a docs chore
    # is never asked to certify the full suite.
    out, code = with_changed_files("") { check_suite({ "kind" => "chore" }, "missing") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
  end

  def test_full_suite_gate_surfaces_in_json_verdict
    out, code = check_suite(SUITE_CONTRACT, "missing", "--json")
    assert_equal 1, code, out
    verdict = JSON.parse(out)
    refute verdict["ready"]
    refute verdict["full_suite"]["ok"]
    assert_equal "missing", verdict["full_suite"]["lanes"]["full-suite"]
    assert(verdict["errors"].any? { |e| e =~ /not certified/ })
  end

  def test_full_suite_bypass_surfaces_in_json_verdict
    devops = SUITE_CONTRACT.merge(
      "checks_run" => SUITE_CONTRACT["checks_run"] + ["[full-suite-bypass] env blocker, see task-x"]
    )
    out, code = check_suite(devops, "missing", "--json")
    assert_equal 0, code, out
    verdict = JSON.parse(out)
    assert verdict["ready"]
    assert verdict["full_suite"]["ok"]
    assert_match(/env blocker/, verdict["full_suite"]["bypass"])
  end

  # --- [integration] FULL-suite gate over the REAL git fingerprint --------------
  # No DOR_CHECK_SUITE_EVIDENCE seam: dor-check recomputes the code fingerprint
  # (git tree hash) from a temp repo and grades the embedded evidence tags against
  # it — the actual production path.

  # A temp repo with one commit; yields [dir, fingerprint] for the CURRENT tree.
  def with_suite_repo
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      File.write(File.join(dir, "app.rb"), "base\n")
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("add -A")
      git.call("commit -q -m init")
      yield dir, suite_fingerprint(dir)
    end
  end

  # The fingerprint dor-check would validate against for `dir` (its real resolver).
  def suite_fingerprint(dir)
    fp = nil
    with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_SUITE_EVIDENCE" => nil, "DOR_CHECK_CHANGED_FILES" => nil) do
      fp = IO.popen("#{BIN} --suite-fingerprint 2>/dev/null", &:read).strip
    end
    fp
  end

  # Run check on the REAL fingerprint path against `dir` (SUITE_EVIDENCE="" disables
  # the default-ok seam so the git fingerprint is computed for real).
  def check_real_suite(dir, devops, *args)
    with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
             "DOR_CHECK_SUITE_EVIDENCE" => "", "DOR_CHECK_CHANGED_FILES" => nil) do
      check(devops, *args)
    end
  end

  def suite_evidence(fp, lanes: %w[full-suite rubocop])
    lanes.map { |lane| "[#{lane}@#{fp}] certified" }
  end

  def test_e2e_fresh_fingerprint_evidence_passes
    with_suite_repo do |dir, fp|
      devops = SUITE_CONTRACT.merge("checks_run" => SUITE_CONTRACT["checks_run"] + suite_evidence(fp))
      out, code = check_real_suite(dir, devops)
      assert_equal 0, code, out
      assert_match(/DoR-to-Merge met/, out)
      assert_match(/certified green at #{fp[0, 12]}/, out)
    end
  end

  def test_e2e_evidence_goes_stale_after_an_edit
    with_suite_repo do |dir, fp|
      devops = SUITE_CONTRACT.merge("checks_run" => SUITE_CONTRACT["checks_run"] + suite_evidence(fp))
      # Edit a tracked file: the fingerprint changes, the embedded evidence is now
      # for older code → REFUSED.
      File.write(File.join(dir, "app.rb"), "base\nedited\n")
      out, code = check_real_suite(dir, devops)
      assert_equal 1, code, out
      assert_match(/STALE/, out)
    end
  end

  def test_e2e_touched_files_only_pr_is_refused
    # The retro case in the real path: [unit]/[integration] tagged, but NO
    # full-suite/rubocop evidence at all → both lanes MISSING → REFUSED.
    with_suite_repo do |dir, _fp|
      out, code = check_real_suite(dir, SUITE_CONTRACT)
      assert_equal 1, code, out
      assert_match(/full-suite: MISSING/, out)
      assert_match(/rubocop: MISSING/, out)
    end
  end

  def test_e2e_partial_evidence_missing_rubocop_is_refused
    # Tests certified but rubocop never run → rubocop MISSING → REFUSED.
    with_suite_repo do |dir, fp|
      devops = SUITE_CONTRACT.merge("checks_run" => SUITE_CONTRACT["checks_run"] + suite_evidence(fp, lanes: %w[full-suite]))
      out, code = check_real_suite(dir, devops)
      assert_equal 1, code, out
      assert_match(/rubocop: MISSING/, out)
      refute_match(/full-suite: (MISSING|STALE)/, out)
    end
  end

  def test_e2e_fingerprint_is_stable_across_the_commit_boundary
    # The checkout-independence property: certify on a DIRTY tree (the pre-commit
    # SOP), then COMMIT the same change — the recomputed fingerprint is identical
    # (a git tree hash is content-addressed), so the SAME evidence still validates.
    # This is why a reviewer's checkout at the committed HEAD credits the evidence.
    with_suite_repo do |dir, _committed_fp|
      File.write(File.join(dir, "app.rb"), "base\nfeature change\n")
      dirty_fp = suite_fingerprint(dir)
      devops = SUITE_CONTRACT.merge("checks_run" => SUITE_CONTRACT["checks_run"] + suite_evidence(dirty_fp))

      out, code = check_real_suite(dir, devops)
      assert_equal 0, code, "pre-commit (dirty) should validate\n#{out}"

      assert system("git -C #{dir} add -A >/dev/null 2>&1")
      assert system("git -C #{dir} commit -q -m feature >/dev/null 2>&1")
      assert_equal dirty_fp, suite_fingerprint(dir), "fingerprint must be stable across the commit"

      out, code = check_real_suite(dir, devops)
      assert_equal 0, code, "post-commit (clean) should still validate the same evidence\n#{out}"
    end
  end
end
