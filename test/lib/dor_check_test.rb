# frozen_string_literal: true

# Standalone test for bin/dor-check (no Rails needed — it shells out to the
# script with --file fixtures). Run directly:
#   ruby -Itest test/lib/dor_check_test.rb
# It is also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

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
        out = IO.popen(SessionEnv.neutralized, "#{BIN} --file #{path} #{args.join(' ')} 2>/dev/null", &:read)
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

  # The fingerprint dor-check resolves when run FROM `dir` with NO DOR_CHECK_DIFF_ROOT
  # override — the cwd-default path (the satellite fix). Contrast suite_fingerprint(dir),
  # which pins the root via the explicit override.
  def fingerprint_running_in(dir)
    IO.popen(SessionEnv.neutralized("DOR_CHECK_DIFF_ROOT" => nil, "DOR_CHECK_SUITE_EVIDENCE" => nil,
                                    "DOR_CHECK_CHANGED_FILES" => nil),
             [BIN, "--suite-fingerprint"], { chdir: dir, err: File::NULL }, &:read).to_s.strip
  end

  # ── [integration] the CODE root follows the agent's worktree (finding #2) ──
  # A satellite ships no gate scripts, so it runs the HUB's dor-check; if the diff
  # root stayed pinned to the hub, the gate would fingerprint the hub tree — a false
  # certification. With no DOR_CHECK_DIFF_ROOT override the root must follow cwd.

  def test_integration_diff_root_defaults_to_the_cwd_worktree
    with_git_repo(staged: ["app/x.rb"]) do |repo_a|
      with_git_repo(staged: ["app/y.rb"]) do |repo_b|
        fp_a_cwd      = fingerprint_running_in(repo_a)  # override UNSET → cwd
        fp_b_cwd      = fingerprint_running_in(repo_b)
        fp_a_explicit = suite_fingerprint(repo_a)       # explicit override (existing helper)

        refute_empty fp_a_cwd, "the cwd-rooted run produces a real fingerprint"
        assert_equal fp_a_explicit, fp_a_cwd,
                     "no override roots at cwd — same fingerprint as an explicit --diff-root"
        refute_equal fp_a_cwd, fp_b_cwd,
                     "the fingerprint follows the cwd worktree, not a repo fixed at the script's location"
      end
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
      base = IO.popen(SessionEnv.neutralized, "#{BIN} --diff-base 2>/dev/null", &:read).strip
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
        assert_match(/doc-only diff \(kind: chore\)/, out)
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

  # The exemption is EARNED by a doc-only diff, never by the kind label alone —
  # so these "exempt without a shape" cases must SHOW a doc-only diff. (They used
  # to pass an EMPTY diff, which now fails closed: see the fail-closed section.)
  def test_chore_kind_is_exempt_without_a_shape
    out, code = with_changed_files("docs/agents/note.md") { check("kind" => "chore") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
    assert_match(/kind: chore/, out)
  end

  def test_cleanup_kind_is_exempt_without_a_shape
    out, code = with_changed_files("docs/agents/note.md") { check("kind" => "cleanup") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
  end

  def test_chore_exemption_in_json_verdict
    out, code = with_changed_files("docs/agents/note.md") { check({ "kind" => "chore" }, "--json") }
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

  # --- [unit] the exemption is DENYLIST-shaped: prove doc-only, or get gated ---
  # The bug (task chore-kind-skips-dor-tiers): the code-diff detector was an
  # ALLOWLIST (app/ lib/ bin/ config/ db/), so any behavioral file OUTSIDE those
  # five prefixes read as "not code" and the chore kept its exemption. PR #512
  # (`kind: chore`) shipped .github/workflows/ci.yml — real CI behavior, plus real
  # tests — and DoR printed "n/a → ready to advance". The fix inverts the polarity:
  # a file is non-behavioral ONLY if it is provably prose (docs/, *.md, LICENSE…).
  # Everything else gates. These tests FAIL on the allowlist.

  def test_chore_shipping_a_ci_workflow_is_refused
    # THE regression: PR #512's exact diff.
    out, code = with_changed_files(".github/workflows/ci.yml\ntest/lib/ci_workflow_triggers_test.rb") do
      check("kind" => "chore")
    end
    assert_equal 1, code, out
    assert_match(/ships a code diff/, out)
    assert_match(%r{\.github/workflows/ci\.yml}, out)
    assert_match(/set devops\.shape/, out)
  end

  def test_chore_shipping_a_gemfile_bump_is_refused
    # A dependency bump is the canonical "chore" — and it changes behavior (the
    # resolved gem graph). It carries tiers like anything else.
    out, code = with_changed_files("Gemfile\nGemfile.lock") { check("kind" => "chore") }
    assert_equal 1, code, out
    assert_match(/ships a code diff/, out)
    assert_match(/Gemfile/, out)
  end

  def test_chore_shipping_root_and_dotfile_config_is_refused
    # Root-level + dotfile config that the allowlist never saw: all behavior.
    ["Rakefile", "package.json", ".rubocop.yml", "Procfile", "app.json"].each do |file|
      out, code = with_changed_files(file) { check("kind" => "chore") }
      assert_equal 1, code, "#{file} should be gated, got:\n#{out}"
      assert_match(/ships a code diff/, out)
    end
  end

  def test_chore_shipping_only_tests_is_refused
    # test/ is executable behavior, and the tier line the author records is TRUE —
    # they just wrote the tests. Cheap to satisfy, honest to declare.
    out, code = with_changed_files("test/lib/ci_workflow_triggers_test.rb") { check("kind" => "chore") }
    assert_equal 1, code, out
    assert_match(/ships a code diff/, out)
  end

  def test_docs_only_sop_chore_stays_exempt
    # PR #513's exact diff — the legitimate skip. It must still pass cleanly.
    files = %w[
      docs/agents/agents/alex/sops/full-cycle.md
      docs/agents/agents/avi/sops/pr-review.md
      docs/agents/agents/steffon/sops/qa-release.md
      docs/agents/modules/heartbeats.md
    ].join("\n")
    out, code = with_changed_files(files) { check("kind" => "chore") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
  end

  # Classify by TYPE, never by DIRECTORY. A `docs/` prefix rule is prose-by-
  # assertion — it would exempt these REAL files, which are executable today:
  #   docs/agents/setup.sh          (mode 100755; fresh-machine bundle + DB bootstrap)
  #   docs/agents/patches/*.patch   (applied to the Codex runtime)
  #   rolio docs/build/workflow.js
  # Where a file was FILED is a declaration; what it IS is evidence.
  def test_docs_rooted_script_is_refused
    ["docs/agents/setup.sh", "docs/agents/patches/codex-session-start.patch", "docs/build/workflow.js"].each do |file|
      out, code = with_changed_files(file) { check("kind" => "chore") }
      assert_equal 1, code, "#{file} lives under docs/ but is EXECUTABLE — it must gate. Got:\n#{out}"
      assert_match(/ships a code diff/, out)
    end
  end

  def test_docs_rooted_prose_and_media_still_skip
    # The legitimate docs skip survives the type-only rule: prose + inert media.
    out, code = with_changed_files("docs/agents/sop.md\ndocs/img/flow.png") { check("kind" => "chore") }
    assert_equal 0, code, out
    assert_match(/doc-only/, out)
  end

  def test_txt_is_not_blanket_prose
    # `.txt` tree-wide would exempt production-served and test-input files.
    ["public/robots.txt", "test/fixtures/files/notes.txt"].each do |file|
      out, code = with_changed_files(file) { check("kind" => "chore") }
      assert_equal 1, code, "#{file} is not prose-by-convention. Got:\n#{out}"
      assert_match(/ships a code diff/, out)
    end
    # …while the prose-by-convention basenames still skip.
    out, code = with_changed_files("LICENSE.txt\nREADME.txt") { check("kind" => "chore") }
    assert_equal 0, code, out
  end

  # --- renames: a path list shows ONE side of a two-sided change ---------------
  # `git diff --name-only` collapses `R100 bin/deploy.sh docs/deploy-notes.md` to
  # the DESTINATION, and `gh pr view --json files` exposes only {..., path}. So a
  # commit renaming an EXECUTABLE into a .md read as "1 file, none behavioral" and
  # took a full exemption — while DELETING a script from bin/. The behavior change
  # is the removal, and it is invisible in the new path. Both sides now classify.

  # A repo with a staged rename old -> new (real git, no injection).
  def with_renamed_file(from, to)
    Dir.mktmpdir do |dir|
      git = ->(args) { assert(system("git -C #{dir} #{args} >/dev/null 2>&1"), "git #{args}") }
      FileUtils.mkdir_p(File.dirname(File.join(dir, from)))
      File.write(File.join(dir, from), "contents\n")
      git.call("init -q")
      git.call("config user.email tester@example.com")
      git.call("config user.name tester")
      git.call("add -A")
      git.call("commit -q -m base")
      FileUtils.mkdir_p(File.dirname(File.join(dir, to)))
      git.call("mv #{from} #{to}")
      yield dir
    end
  end

  def test_code_to_doc_rename_is_refused
    # THE repro: renaming a script into prose must NOT buy an exemption.
    with_renamed_file("bin/deploy.sh", "docs/deploy-notes.md") do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 1, code, out
      assert_match(/ships a code diff/, out)
      assert_match(%r{bin/deploy\.sh}, out) # the OLD path is what proves it
    end
  end

  def test_doc_to_code_rename_is_refused
    # The other direction always gated (its new path is behavioral) — lock it in.
    with_renamed_file("docs/x.md", "bin/x.sh") do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 1, code, out
      assert_match(/ships a code diff/, out)
    end
  end

  def test_prose_to_prose_rename_still_skips
    # Don't over-correct: a genuine docs reshuffle is still doc-only.
    with_renamed_file("docs/old-sop.md", "docs/new-sop.md") do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 0, code, out
      assert_match(/doc-only/, out)
    end
  end

  def test_pr_source_classifies_both_sides_of_a_rename
    # The :pr path resolves via the REST files endpoint, which carries
    # previous_filename — so BOTH sides arrive in the list, from a clean checkout.
    with_git_repo do |dir|
      out, code = with_env(
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD", "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_PR_FILES" => "docs/deploy-notes.md\nbin/deploy.sh"
      ) { check("kind" => "chore", "pr_url" => "https://github.com/o/r/pull/1") }
      assert_equal 1, code, out
      assert_match(%r{bin/deploy\.sh}, out)
    end
  end

  # [unit] the parser itself — both sides out of --name-status -M.
  def test_name_status_parser_emits_both_sides_of_a_rename
    require_relative "../../bin/lib/code_diff"
    paths = CodeDiff.paths_from_name_status(
      "R100\tbin/deploy.sh\tdocs/deploy-notes.md\nM\tapp/models/task.rb\nD\tlib/gone.rb\n"
    )
    assert_equal ["bin/deploy.sh", "docs/deploy-notes.md", "app/models/task.rb", "lib/gone.rb"], paths
    assert_equal ["bin/deploy.sh", "app/models/task.rb", "lib/gone.rb"], CodeDiff.code_files(paths)
  end

  def test_doc_only_skip_names_the_observed_diff
    # A skip must be LOUD and evidence-shaped: it says WHAT it looked at, not just
    # "n/a (kind: chore)". A silent skip is what let the bug hide for two PRs.
    out, code = with_changed_files("docs/agents/foo.md\nREADME.md") { check("kind" => "chore") }
    assert_equal 0, code, out
    assert_match(/doc-only/, out)
    assert_match(/2 file/, out)
    assert_match(%r{docs/agents/foo\.md}, out)
    refute_match(/^✓ DoR-to-Merge n\/a.*non-code task \(kind: chore\)$/, out)
  end

  def test_mostly_docs_plus_one_behavioral_file_is_refused
    # The dangerous shape: a diff that LOOKS like a docs chore with one code line
    # smuggled in. Every file must be non-behavioral, not most of them.
    out, code = with_changed_files(
      "docs/a.md\ndocs/b.md\ndocs/c.md\nREADME.md\n.github/workflows/ci.yml"
    ) { check("kind" => "chore") }
    assert_equal 1, code, out
    assert_match(/ships a code diff/, out)
    assert_match(%r{\.github/workflows/ci\.yml}, out)
  end

  # --- [unit] fail-closed: an undetermined diff never buys an exemption --------
  # "We couldn't see a code diff" is NOT "there is no code diff". The old detector
  # defaulted to EXEMPT on an empty/unreadable view, so running the gate from a
  # checkout that couldn't see the branch silently disarmed it.

  def test_empty_diff_at_the_merge_gate_fails_closed
    out, code = with_changed_files("") { check("kind" => "chore") }
    assert_equal 1, code, out
    assert_match(/could not be proven doc-only|no diff/i, out)
  end

  def test_empty_diff_at_the_merge_gate_fails_closed_in_json
    out, code = with_changed_files("") { check({ "kind" => "chore" }, "--json") }
    assert_equal 1, code, out
    verdict = JSON.parse(out)
    refute verdict["ready"]
    refute verdict["exempt"]
    assert_equal "indeterminate", verdict["diff_source"]
  end

  def test_build_gate_still_exempts_a_chore_with_no_code_yet
    # The legitimate empty diff: at DESIGN time no code exists. The build gate
    # enforces no tiers anyway, so leniency there cannot disarm the test gate.
    out, code = with_changed_files("") { check({ "kind" => "chore" }, "--gate build") }
    assert_equal 0, code, out
    assert_match(/DoR n\/a/, out)
  end

  def test_exempt_json_verdict_reports_its_diff_evidence
    out, code = with_changed_files("docs/x.md") { check({ "kind" => "chore" }, "--json") }
    assert_equal 0, code, out
    verdict = JSON.parse(out)
    assert verdict["ready"]
    assert verdict["exempt"]
    assert_equal "chore", verdict["kind"]
    assert_equal "injected", verdict["diff_source"]
    assert_equal [], verdict["code_files"]
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
    # docs/ + *.md across all three states — nothing behavioral → stays exempt.
    with_git_repo(staged: ["README.md"], unstaged: ["docs/guide.md"], untracked: ["NOTES.md"]) do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 0, code, out
      assert_match(/DoR n\/a/, out)
      assert_match(/doc-only/, out)
    end
  end

  # --- [integration] real git: the behavioral files the ALLOWLIST couldn't see --

  def test_real_git_workflow_file_gates_a_chore
    # PR #512 end-to-end through the REAL git detector (no injection).
    with_git_repo(staged: [".github/workflows/ci.yml"], untracked: ["test/lib/ci_workflow_triggers_test.rb"]) do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 1, code, out
      assert_match(/ships a code diff/, out)
      assert_match(%r{\.github/workflows/ci\.yml}, out)
    end
  end

  def test_real_git_gemfile_bump_gates_a_chore
    with_git_repo(unstaged: ["Gemfile.lock"]) do |dir|
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 1, code, out
      assert_match(/ships a code diff/, out)
    end
  end

  # --- [integration] fail-closed on an undetermined diff ----------------------

  def test_clean_working_tree_chore_fails_closed_at_the_merge_gate
    # The silent-disarm vector: run the gate from a checkout that cannot SEE the
    # branch (a clean primary) and the old detector reported "no code diff" →
    # exempt. An empty view proves nothing about what the PR ships.
    with_git_repo do |dir| # nothing changed
      out, code = check_against(dir, "kind" => "chore")
      assert_equal 1, code, out
      assert_match(/could not be proven doc-only/i, out)
    end
  end

  def test_unreadable_git_root_fails_closed
    # git can't read a non-repo dir → indeterminate → enforce, never default-exempt.
    Dir.mktmpdir do |dir|
      out, code = with_env(
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
        "DOR_CHECK_CHANGED_FILES" => nil, "DOR_CHECK_PR_FILES" => nil
      ) { check("kind" => "chore") }
      assert_equal 1, code, out
      assert_match(/could not be proven doc-only/i, out)
    end
  end

  def test_changed_files_injection_overrides_real_git
    # A real code file is present, but the injected DOC-only list must win → exempt.
    with_git_repo(untracked: ["app/models/widget.rb"]) do |dir|
      with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD",
               "DOR_CHECK_CHANGED_FILES" => "docs/guide.md") do
        out, code = check("kind" => "chore")
        assert_equal 0, code, out
        assert_match(/DoR n\/a/, out)
      end
    end
  end

  # --- [integration] the PR's files are the merge gate's source of truth -------
  # At the merge boundary the artifact under gate is the PR, not whatever tree the
  # reviewer happens to be standing in. Reviewers run the gate-zero dor-check from
  # a PRIMARY checkout (the task branch isn't checked out there), so a local-only
  # detector sees an empty diff. Reading the PR's files makes the gate correct from
  # anywhere — and keeps the honest docs-only chore passing.

  def test_pr_files_gate_a_code_chore_from_a_clean_checkout
    with_git_repo do |dir| # clean tree: the local view sees NOTHING
      out, code = with_env(
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD", "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_PR_FILES" => ".github/workflows/ci.yml\ntest/lib/ci_workflow_triggers_test.rb"
      ) { check("kind" => "chore", "pr_url" => "https://github.com/o/r/pull/512") }
      assert_equal 1, code, out
      assert_match(/ships a code diff/, out)
      assert_match(%r{\.github/workflows/ci\.yml}, out)
    end
  end

  def test_pr_files_keep_a_docs_only_chore_exempt_from_a_clean_checkout
    with_git_repo do |dir|
      out, code = with_env(
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD", "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_PR_FILES" => "docs/agents/modules/heartbeats.md\ndocs/agents/agents/avi/sops/pr-review.md"
      ) { check("kind" => "chore", "pr_url" => "https://github.com/o/r/pull/513") }
      assert_equal 0, code, out
      assert_match(/DoR n\/a/, out)
      assert_match(/doc-only/, out)
    end
  end

  def test_unverifiable_pr_files_fall_back_to_the_local_diff
    # gh unavailable → fall back to the local working tree rather than fail closed
    # on a diff we CAN read. (An unreadable local tree then fails closed above.)
    with_git_repo(untracked: ["app/models/widget.rb"]) do |dir|
      out, code = with_env(
        "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_DIFF_BASE" => "HEAD", "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_PR_FILES" => "unverified"
      ) { check("kind" => "chore", "pr_url" => "https://github.com/o/r/pull/1") }
      assert_equal 1, code, out
      assert_match(/ships a code diff/, out)
      assert_match(%r{app/models/widget\.rb}, out)
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
  # is the sole variable — including post_deploy_cmd, so a branch whose own working
  # tree happens to touch a seed/migration (this check() runs against the live tree)
  # doesn't trip the post-deploy gate and leak into these suite-gate assertions.
  SUITE_CONTRACT = {
    "shape" => "backend", "repositories" => ["mcritchie-studio"],
    "risk_tags" => ["devops"], "acceptance" => ["enforce the full suite"],
    "test_plan" => ["unit", "integration"], "post_deploy_cmd" => "none",
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
    # An exempt DOC-ONLY chore short-circuits before the suite gate — a docs chore
    # is never asked to certify the full suite. (It must SHOW the doc-only diff:
    # an empty diff no longer earns the exemption — it fails closed.)
    out, code = with_changed_files("docs/agents/note.md") { check_suite({ "kind" => "chore" }, "missing") }
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
      fp = IO.popen(SessionEnv.neutralized, "#{BIN} --suite-fingerprint 2>/dev/null", &:read).strip
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

  def test_e2e_fingerprint_is_stable_across_the_commit_boundary_for_a_new_file
    # Same checkout-independence property, but for a change that ADDS a file —
    # the case `git stash create` silently dropped (the new file was absent from
    # the pre-commit fingerprint, present in the committed tree → false STALE on
    # the reviewer's checkout). Certify with a new untracked file present, commit
    # it, and the SAME evidence must still validate at the committed HEAD.
    with_suite_repo do |dir, _committed_fp|
      File.write(File.join(dir, "added_feature.rb"), "brand new\n") # untracked
      dirty_fp = suite_fingerprint(dir)
      devops = SUITE_CONTRACT.merge("checks_run" => SUITE_CONTRACT["checks_run"] + suite_evidence(dirty_fp))

      out, code = check_real_suite(dir, devops)
      assert_equal 0, code, "pre-commit (new file untracked) should validate\n#{out}"

      assert system("git -C #{dir} add -A >/dev/null 2>&1")
      assert system("git -C #{dir} commit -q -m add-feature >/dev/null 2>&1")
      assert_equal dirty_fp, suite_fingerprint(dir), "fingerprint must be stable across committing a new file"

      out, code = check_real_suite(dir, devops)
      assert_equal 0, code, "post-commit (clean) should still validate the same evidence\n#{out}"
    end
  end

  # --- canonical post_deploy_cmd SUGGESTION (warn, never reject) ----------------
  # rails runner accepts a file path directly, so `bin/rails runner <path>` is the
  # canonical, paren-free form. A valid-but-fragile `runner "load Rails.root.join
  # (...)"` is the shape that made the seed-54 ship brittle through `heroku run`,
  # so dor-check SUGGESTS the canonical form WITHOUT rejecting the (working) cmd.
  # A non-data code diff isolates the suggestion (no post-deploy nudge fires).

  def test_fragile_runner_load_is_accepted_with_a_canonical_suggestion
    cmd = "bin/rails runner 'load Rails.root.join(\"db/seeds/54_demo.rb\").to_s'"
    out, code = with_changed_files("app/models/agent.rb") do
      check(BACKEND_CONTRACT.merge("post_deploy_cmd" => cmd))
    end
    assert_equal 0, code, out # SUGGESTION ONLY — never blocks
    assert_match(/DoR-to-Merge met/, out)
    assert_match(/suggestion/i, out, "the fragile runner form earns a nudge")
    assert_match(%r{bin/rails runner db/seeds/54_demo\.rb}, out, "suggests the canonical paren-free form")
  end

  def test_fragile_runner_with_percent_q_path_is_suggested
    # The exact seed-54 %q(...) shape that broke the heroku-run round-trip.
    cmd = 'bin/rails runner "load Rails.root.join(%q(db/seeds/54_demo.rb)).to_s"'
    out, code = with_changed_files("app/models/agent.rb") do
      check(BACKEND_CONTRACT.merge("post_deploy_cmd" => cmd))
    end
    assert_equal 0, code, out
    assert_match(%r{bin/rails runner db/seeds/54_demo\.rb}, out)
  end

  def test_canonical_runner_path_form_gets_no_suggestion
    out, code = with_changed_files("app/models/agent.rb") do
      check(BACKEND_CONTRACT.merge("post_deploy_cmd" => "bin/rails runner db/seeds/54_demo.rb"))
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    refute_match(/suggestion/i, out, "the canonical form needs no nudge")
  end

  def test_fragile_runner_suggestion_surfaces_in_json_verdict
    cmd = "bin/rails runner 'load Rails.root.join(\"db/seeds/54_demo.rb\").to_s'"
    out, code = with_changed_files("app/models/agent.rb") do
      check(BACKEND_CONTRACT.merge("post_deploy_cmd" => cmd), "--json")
    end
    assert_equal 0, code, out
    verdict = JSON.parse(out)
    assert verdict["ready"], "a suggestion never flips readiness"
    assert(verdict["suggestions"].any? { |s| s =~ /canonical/ }, "the suggestion rides in the json verdict")
  end

  # --- Gem-publish seam guard (merge gate) -----------------------------------

  # A minimal Gemfile.lock pinning studio-engine to `version`.
  def lock_with(version)
    "GEM\n  remote: https://rubygems.org/\n  specs:\n" \
      "    studio-engine (#{version})\n\nDEPENDENCIES\n  studio-engine\n"
  end

  # A temp repo carrying a Gemfile + Gemfile.lock for the guard to read, with the
  # branch diff pointed at Gemfile (the trigger).
  def with_gemfile_diff(gemfile, lock)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), gemfile)
      File.write(File.join(dir, "Gemfile.lock"), lock)
      with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_CHANGED_FILES" => "Gemfile") { yield }
    end
  end

  def test_merge_gate_blocks_a_gemfile_bump_the_lock_cannot_satisfy
    out, code = with_gemfile_diff(%(gem "studio-engine", "~> 0.9"\n), lock_with("0.8.0")) do
      check(BACKEND_CONTRACT)
    end
    assert_equal 1, code, out
    assert_match(/studio-engine.*Gemfile\.lock pins 0\.8\.0/, out)
    assert_match(/gem-publish seam/, out)
  end

  def test_merge_gate_passes_when_the_lock_satisfies_the_bumped_constraint
    out, code = with_gemfile_diff(%(gem "studio-engine", "~> 0.9"\n), lock_with("0.9.0")) do
      check(BACKEND_CONTRACT)
    end
    assert_equal 0, code, out
  end

  def test_gem_guard_does_not_fire_when_the_branch_left_the_gemfile_alone
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "Gemfile"), %(gem "studio-engine", "~> 0.9"\n))
      File.write(File.join(dir, "Gemfile.lock"), lock_with("0.8.0"))
      out, code = with_env("DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_CHANGED_FILES" => "app/models/x.rb") do
        check(BACKEND_CONTRACT)
      end
      assert_equal 0, code, out # Gemfile not in the diff → a pre-existing state, not this branch's
    end
  end

  def test_gem_guard_ignores_a_path_or_git_source_bridge
    out, code = with_gemfile_diff(%(gem "studio-engine", path: "../studio-engine"\n), lock_with("0.8.0")) do
      check(BACKEND_CONTRACT)
    end
    assert_equal 0, code, out # the local-dev bridge isn't a versioned constraint
  end

  # --- CI-status gate: the merge gate refuses a red / not-yet-green PR ----------
  # Closes the report's #1 blocker class — a PR green LOCALLY but red on GitHub CI,
  # because the local cert doesn't run the browser test:system lane. DOR_CHECK_CI_STATUS
  # injects the verdict so these never shell out to gh (mirrors DOR_CHECK_SUITE_EVIDENCE).
  CI_PR = BACKEND_CONTRACT.merge("pr_url" => "https://github.com/amcritchie/mcritchie-studio/pull/1").freeze

  def ci_check(state, devops = CI_PR, *args)
    with_changed_files("app/models/agent.rb") do
      with_env("DOR_CHECK_CI_STATUS" => state) { check(devops, *args) }
    end
  end

  def test_merge_gate_fails_when_github_ci_is_red
    out, code = ci_check("red")
    assert_equal 1, code, out
    assert_match(/GitHub CI is RED/, out)
    assert_match(/not ready to advance/, out)
  end

  def test_pending_ci_is_a_loud_suggestion_not_a_block_at_submit
    # ci-gate-review-handoff: the builder submits WITHOUT waiting for CI — the CI
    # wait moved from the builder's wall-clock to the review handoff. Submit-side
    # (--gate-role builder, the default), a still-running CI is a LOUD suggestion,
    # never a block; pr-review's supervisor holds the authoritative verdict.
    out, code = ci_check("pending")
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    assert_match(/still RUNNING/, out)
    assert_match(/gate-zero/, out, "the suggestion names where the authoritative CI verdict now lives")
  end

  def test_review_gate_zero_still_blocks_pending_ci
    # The review-side run keeps today's strict semantics: the primary's gate-zero
    # is the authoritative CI verdict, so pending still blocks there.
    out, code = ci_check("pending", CI_PR, "--gate-role", "review")
    assert_equal 1, code, out
    assert_match(/still RUNNING/, out)
    assert_match(/not ready to advance/, out)
  end

  def test_review_gate_zero_still_blocks_red_ci
    out, code = ci_check("red", CI_PR, "--gate-role", "review")
    assert_equal 1, code, out
    assert_match(/GitHub CI is RED/, out)
  end

  def test_merge_gate_passes_when_ci_is_green
    out, code = ci_check("green")
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    assert_match(/GitHub CI green/, out)
  end

  def test_gh_or_network_error_is_a_note_never_a_block
    out, code = ci_check("unverified")
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    assert_match(/UNVERIFIED/, out)
  end

  def test_merge_gate_blocks_a_closed_pr
    # A closed PR's green checks are HISTORICAL, not a live review target — the gate
    # must not let a stale pr_url pass as green (carl's PR #399 review catch).
    out, code = ci_check("closed")
    assert_equal 1, code, out
    assert_match(/is CLOSED/, out)
    assert_match(/not ready to advance/, out)
  end

  def test_merge_gate_blocks_a_merged_pr
    out, code = ci_check("merged")
    assert_equal 1, code, out
    assert_match(/is MERGED/, out)
    assert_match(/not ready to advance/, out)
  end

  # --- conflicted PR (mergeStateStatus DIRTY): a HARD, actionable blocker --------
  # The PR-#509 stall (2026-07-12): a merge-conflicted PR gets NO GitHub CI at all —
  # GitHub cannot compute the merge commit, so the pull_request workflow never
  # fires. Pre-fix the gate read that as :none → a soft "CI UNVERIFIED" suggestion,
  # and the PR sat in submitted forever looking healthy. DIRTY must block in BOTH
  # roles, with the fix named (rebase/merge release), and stay distinct from
  # pending/none — which mean "CI still coming" and genuinely defer.

  def test_merge_gate_blocks_a_conflicted_pr
    out, code = ci_check("conflicted")
    assert_equal 1, code, out
    assert_match(/CONFLICTED/i, out)
    assert_match(/rebase|merge release/i, out, "the blocker names the fix")
    assert_match(/not ready to advance/, out)
  end

  def test_review_gate_zero_blocks_a_conflicted_pr
    out, code = ci_check("conflicted", CI_PR, "--gate-role", "review")
    assert_equal 1, code, out
    assert_match(/CONFLICTED/i, out)
    assert_match(/not ready to advance/, out)
  end

  def test_conflicted_is_distinct_from_no_checks_yet
    # :none stays a non-blocking note (CI genuinely still coming); :conflicted is
    # the hard blocker. The distinction IS the bug fix — folding them together is
    # what made the stall invisible.
    out, code = ci_check("none")
    assert_equal 0, code, out
    assert_match(/UNVERIFIED/, out)
    refute_match(/CONFLICTED/i, out)
  end

  def test_ci_conflicted_surfaces_in_the_json_verdict
    out, code = ci_check("conflicted", CI_PR, "--json")
    assert_equal 1, code, out
    j = JSON.parse(out)
    refute j["ready"]
    assert_equal "conflicted", j.dig("ci", "state")
    assert(j["errors"].any? { |e| e.match?(/CONFLICTED/i) }, out)
  end

  def test_missing_pr_is_silent_and_stays_ready
    # No PR yet + no injection → :no_pr via the real (gh-free) path. dor-check runs
    # before the PR exists on the normal path, so the CI gate has nothing to verify:
    # it stays SILENT (no note, no block, no shell-out to gh).
    out, code = with_changed_files("app/models/agent.rb") do
      with_env("DOR_CHECK_CI_STATUS" => nil) { check(BACKEND_CONTRACT) }
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    refute_match(/GitHub CI|CI gate|UNVERIFIED/, out)
  end

  def test_build_gate_ignores_ci_status
    # DoR-to-Build never looks at CI (no PR/code yet) — a red token must not block build.
    out, code = with_env("DOR_CHECK_CI_STATUS" => "red") do
      check({ "shape" => "backend", "repositories" => ["m"], "risk_tags" => ["x"],
              "acceptance" => ["a"], "test_plan" => ["unit"], "checks_run" => [] }, "--gate", "build")
    end
    assert_equal 0, code, out
    assert_match(/DoR-to-Build met/, out)
  end

  def test_ci_red_surfaces_in_the_json_verdict
    out, code = ci_check("red", CI_PR, "--json")
    assert_equal 1, code, out
    j = JSON.parse(out)
    refute j["ready"]
    assert_equal "red", j.dig("ci", "state")
    assert(j["errors"].any? { |e| e.match?(/RED/) }, out)
  end

  # --- FAST-cert route: fresh [fast-cert@<fp>] evidence + GREEN GitHub CI --------
  # The 90/10 rethink: CI already runs the FULL suite + test:system per PR push and
  # this gate blocks on CI green anyway, so a fresh bin/fast-check cert (diff-mapped
  # tests + core spine + scoped rubocop) is accepted as the suite gate WHEN CI is
  # green. Red/pending CI still blocks; a missing/unverified CI does NOT credit the
  # fast cert (the full net hasn't provably run); full-suite evidence and the
  # [full-suite-bypass] hatch keep working. Driven by the DOR_CHECK_SUITE_EVIDENCE
  # fast_fresh/fast_stale tokens + DOR_CHECK_CI_STATUS (unit) and the REAL
  # fingerprint path (integration).

  def fast_check_ci(evidence, ci_state, devops = CI_PR, *args)
    with_changed_files("app/models/agent.rb") do
      with_env("DOR_CHECK_SUITE_EVIDENCE" => evidence, "DOR_CHECK_CI_STATUS" => ci_state) do
        check(devops, *args)
      end
    end
  end

  def test_fresh_fast_cert_with_green_ci_passes_merge_gate
    out, code = fast_check_ci("fast_fresh", "green")
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    assert_match(/fast cert accepted/, out)
    assert_match(/GitHub CI green/, out)
  end

  def test_fresh_fast_cert_with_unreported_ci_is_credited_provisionally_at_submit
    # ci-gate-review-handoff: CI :none (an open PR whose checks haven't reported
    # yet — the seconds after `gh pr ready`) gets the same PROVISIONAL credit as
    # pending. The review gate-zero still demands the settled green.
    out, code = fast_check_ci("fast_fresh", "none")
    assert_equal 0, code, out
    assert_match(/PROVISIONALLY/, out)
  end

  def test_fresh_fast_cert_with_red_ci_is_refused
    out, code = fast_check_ci("fast_fresh", "red")
    assert_equal 1, code, out
    assert_match(/GitHub CI is RED/, out)
    assert_match(/fast-cert evidence is FRESH/, out, "the suite gate refuses too — fast needs CI green")
  end

  def test_fresh_fast_cert_with_pending_ci_is_credited_provisionally_at_submit
    # ci-gate-review-handoff: submit-side, a fresh fast cert with CI still running
    # is credited PROVISIONALLY — the builder hands off now, and the review-side
    # gate-zero (strict) holds the authoritative CI verdict.
    out, code = fast_check_ci("fast_fresh", "pending")
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    assert_match(/fast cert accepted PROVISIONALLY/, out)
    assert_match(/gate-zero/, out, "the provisional credit names the authoritative verdict's home")
  end

  # --- CI :unreadable — the gate names its own blindness ----------------------
  #
  # task dor-check-misses-rolio-ci (2026-07-13): a fine-grained PAT with no
  # `Checks: Read` on the PRIVATE rolio repo made `gh pr checks` 403, dor-check
  # folded that into a bare UNVERIFIED, and every rolio task was quietly denied the
  # fast-cert route — with a message telling the builder to "push the branch and open
  # the PR" for a PR that was already open and already GREEN. The gate must instead
  # say: this is a CREDENTIAL fault, on THIS repo, fixed by THIS grant.

  ROLIO_PR = BACKEND_CONTRACT.merge("pr_url" => "https://github.com/amcritchie/rolio/pull/23").freeze

  def test_unreadable_ci_is_reported_as_a_credential_fault_naming_the_repo
    out, = ci_check("unreadable", ROLIO_PR)
    assert_match(/UNREADABLE/, out, "the state is named, not collapsed into UNVERIFIED")
    assert_match(/CREDENTIAL fault/, out, "the CAUSE is named")
    assert_match(%r{amcritchie/rolio}, out, "the REPO is named")
    assert_match(/Checks: Read/, out, "the exact GRANT is named")
    assert_match(/gh pr checks <pr> --repo/, out, "the VERIFY command is named")
  end

  def test_unreadable_ci_does_NOT_unlock_the_fast_cert_route
    # HONESTY, NOT LENIENCY. This is the whole discipline of the change: naming the
    # blindness must not become an EXCUSE for it. A fast cert is only credited
    # alongside a CI green we can actually READ — an unreadable CI is not a green,
    # so it blocks exactly as hard as it did before this change. If this test ever
    # goes green with exit 0, the gate has been made easier to pass.
    out, code = fast_check_ci("fast_fresh", "unreadable", ROLIO_PR)
    assert_equal 1, code, "an unreadable CI must NOT credit a fast cert:\n#{out}"
    assert_match(/fast-cert evidence is FRESH/, out)
    refute_match(/PROVISIONALLY/, out, "no provisional credit on a CI we cannot read")
  end

  def test_unreadable_ci_refuses_the_fast_cert_WITHOUT_the_re_run_lie
    # The regression on the guidance TEXT. The old message sent the builder to
    # "push the branch and open the PR, then re-run dor-check" — futile advice that
    # is exactly how a gate teaches people to ignore it. It must now point at the
    # token, and must NOT tell them to open a PR that already exists.
    out, = fast_check_ci("fast_fresh", "unreadable", ROLIO_PR)
    refute_match(/push the branch and open the PR/, out, "the futile re-run advice must be gone")
    assert_match(/re-running will never clear it/i, out, "the gate says re-running cannot help")
    assert_match(/bin\/full-suite-check/, out, "and names the route that DOES work today")
  end

  def test_unreadable_ci_still_blocks_at_the_review_gate_zero
    out, code = fast_check_ci("fast_fresh", "unreadable", ROLIO_PR, "--gate-role", "review")
    assert_equal 1, code, out
  end

  def test_a_readable_but_unrun_ci_is_still_plain_none_not_unreadable
    # Guard the boundary from the other side: the honest "no run yet" keeps its old
    # meaning and its old PROVISIONAL credit. :unreadable must not swallow :none.
    out, code = fast_check_ci("fast_fresh", "none", CI_PR)
    assert_equal 0, code, out
    assert_match(/PROVISIONALLY/, out)
    refute_match(/CREDENTIAL fault/, out)
  end

  def test_review_gate_zero_refuses_a_fast_cert_until_ci_is_green
    # The strict pairing survives on the review side: fresh fast evidence +
    # pending CI is NOT credited at gate-zero — red/pending both block there.
    out, code = fast_check_ci("fast_fresh", "pending", CI_PR, "--gate-role", "review")
    assert_equal 1, code, out
    assert_match(/fast-cert evidence is FRESH/, out)
    assert_match(/still RUNNING/, out)
  end

  def test_fresh_fast_cert_without_a_pr_is_refused
    # No pr_url + no injection → the real :no_pr path: CI is silent, but silent ≠
    # green — the fast cert stays uncredited until the PR exists and CI passes.
    out, code = with_changed_files("app/models/agent.rb") do
      with_env("DOR_CHECK_SUITE_EVIDENCE" => "fast_fresh", "DOR_CHECK_CI_STATUS" => nil) do
        check(BACKEND_CONTRACT)
      end
    end
    assert_equal 1, code, out
    assert_match(/fast-cert evidence is FRESH/, out)
  end

  def test_stale_fast_cert_is_refused_even_with_green_ci
    out, code = fast_check_ci("fast_stale", "green")
    assert_equal 1, code, out
    assert_match(/fast-cert: STALE/, out)
    refute_match(/DoR-to-Merge met/, out)
  end

  def test_full_evidence_still_passes_without_any_ci_pairing
    # The FULL route is unchanged: full-suite + rubocop evidence needs no CI green
    # (the CI gate itself still blocks red/pending independently — "none" doesn't).
    out, code = fast_check_ci("ok", "none")
    assert_equal 0, code, out
    assert_match(/DoR-to-Merge met/, out)
    refute_match(/fast cert accepted/, out)
  end

  def test_missing_evidence_refusal_offers_the_fast_route
    out, code = fast_check_ci("missing", "green")
    assert_equal 1, code, out
    assert_match(%r{bin/fast-check}, out, "the refusal teaches both certification routes")
    assert_match(%r{bin/full-suite-check}, out)
  end

  def test_fast_route_surfaces_in_the_json_verdict
    out, code = fast_check_ci("fast_fresh", "green", CI_PR, "--json")
    assert_equal 0, code, out
    j = JSON.parse(out)
    assert j["ready"]
    assert_equal "fast", j.dig("full_suite", "route")
    assert_equal "fresh", j.dig("full_suite", "lanes", "fast-cert")
    refute j.dig("full_suite", "ok"), "ok stays the FULL-cert verdict; fast is a distinct route"
  end

  def test_full_route_surfaces_in_the_json_verdict
    out, code = fast_check_ci("ok", "green", CI_PR, "--json")
    assert_equal 0, code, out
    j = JSON.parse(out)
    assert_equal "full", j.dig("full_suite", "route")
  end

  def test_provisional_fast_route_surfaces_in_the_json_verdict
    out, code = fast_check_ci("fast_fresh", "pending", CI_PR, "--json")
    assert_equal 0, code, out
    j = JSON.parse(out)
    assert j["ready"]
    assert_equal "fast-provisional", j.dig("full_suite", "route")
    assert_equal "pending", j.dig("ci", "state")
  end

  def test_bypass_route_surfaces_in_the_json_verdict
    devops = CI_PR.merge(
      "checks_run" => CI_PR["checks_run"] + ["[full-suite-bypass] env blocker, tracked in task-x"]
    )
    out, code = fast_check_ci("missing", "green", devops, "--json")
    assert_equal 0, code, out
    j = JSON.parse(out)
    assert_equal "bypass", j.dig("full_suite", "route")
  end

  # --- [integration] fast route over the REAL git fingerprint --------------------

  def test_e2e_fresh_fast_cert_evidence_with_green_ci_passes
    with_suite_repo do |dir, fp|
      devops = CI_PR.merge("checks_run" => CI_PR["checks_run"] + ["[fast-cert@#{fp}] fast cert green"])
      out, code = with_env("DOR_CHECK_CI_STATUS" => "green") { check_real_suite(dir, devops) }
      assert_equal 0, code, out
      assert_match(/fast cert accepted at #{fp[0, 12]}/, out)
    end
  end

  def test_e2e_fast_cert_evidence_goes_stale_after_an_edit
    with_suite_repo do |dir, fp|
      devops = CI_PR.merge("checks_run" => CI_PR["checks_run"] + ["[fast-cert@#{fp}] fast cert green"])
      File.write(File.join(dir, "app.rb"), "base\nedited\n")
      out, code = with_env("DOR_CHECK_CI_STATUS" => "green") { check_real_suite(dir, devops) }
      assert_equal 1, code, out
      assert_match(/fast-cert: STALE/, out)
    end
  end

  def test_e2e_fast_cert_evidence_with_unsettled_ci_is_provisional_at_submit
    with_suite_repo do |dir, fp|
      devops = CI_PR.merge("checks_run" => CI_PR["checks_run"] + ["[fast-cert@#{fp}] fast cert green"])
      out, code = with_env("DOR_CHECK_CI_STATUS" => "pending") { check_real_suite(dir, devops) }
      assert_equal 0, code, out
      assert_match(/fast cert accepted PROVISIONALLY at #{fp[0, 12]}/, out)
    end
  end

  def test_e2e_fast_cert_evidence_without_green_ci_is_refused_at_review_gate_zero
    with_suite_repo do |dir, fp|
      devops = CI_PR.merge("checks_run" => CI_PR["checks_run"] + ["[fast-cert@#{fp}] fast cert green"])
      out, code = with_env("DOR_CHECK_CI_STATUS" => "none") { check_real_suite(dir, devops, "--gate-role", "review") }
      assert_equal 1, code, out
      assert_match(/fast-cert evidence is FRESH/, out)
    end
  end
end
