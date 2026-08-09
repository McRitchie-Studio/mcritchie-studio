# frozen_string_literal: true

# Regression for the review-role suite-fingerprint ROOTING in bin/dor-check +
# bin/lib/full_suite_gate.rb.
#   ruby -Itest test/lib/dor_check_review_fingerprint_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# The bug (found 2026-07-09 review wave): a PRIMARY reviewer runs
# `bin/dor-check <task> --gate-role review` from the PRIMARY checkout — which is on
# release/main, NOT the task's branch. The full-suite gate fingerprinted the cwd
# WORKING TREE there, so it graded the builder's cert against a totally different
# tree → a FALSE STALE. The fix: --gate-role review roots the suite fingerprint at
# the TASK BRANCH's committed tree (origin/feat/<slug> ^{tree}, content-addressed
# == the tree the builder certified before pushing). Builder-side is unchanged.
#
# Standalone (no Rails): the module is `load`ed for unit tests, and bin/dor-check
# is shelled with --file fixtures for the end-to-end review-role assertions.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

load File.expand_path("../../bin/lib/full_suite_gate.rb", __dir__)

class DorCheckReviewFingerprintTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)

  # ── git fixture ────────────────────────────────────────────────────────────

  def git_out(dir, *args)
    IO.popen(["git", "-C", dir, *args], err: File::NULL, &:read).to_s.strip
  end

  def git!(dir, *args)
    assert system("git", "-C", dir, *args, out: File::NULL, err: File::NULL), "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # A throwaway repo mirroring the reviewer's world: an initial commit on the base
  # branch, then a feat/x branch carrying the "PR head" (the builder's certified
  # tree), an origin/feat/x remote-tracking ref (what a reviewer has post-fetch,
  # unless `with_origin: false`), left checked out on the BASE branch — the primary
  # checkout the reviewer runs from. Yields [dir, base_branch, branch_tree_hash].
  def with_reviewer_repo(with_origin: true)
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      git!(dir, "init", "-q")
      git!(dir, "config", "user.email", "t@t.co")
      git!(dir, "config", "user.name", "T")
      write(dir, "README.md", "base\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "init")
      base = git_out(dir, "rev-parse", "--abbrev-ref", "HEAD")

      git!(dir, "checkout", "-q", "-b", "feat/x")
      write(dir, "app/services/widget.rb", "class Widget; end\n")
      write(dir, "README.md", "base\nfeature\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "feat")
      branch_tree = git_out(dir, "rev-parse", "feat/x^{tree}")
      git!(dir, "update-ref", "refs/remotes/origin/feat/x", "feat/x") if with_origin

      git!(dir, "checkout", "-q", base) # back to the primary/reviewer checkout state
      yield dir, base, branch_tree
    end
  end

  # Two SEPARATE repos, mirroring the real review world: a `hub` the reviewer stands
  # in (mcritchie-studio primary, on its base branch, with NO feat/x anywhere), and a
  # satellite whose task worktree lives at <projects>/satellite-app/.worktrees/<slug>
  # and carries the builder's certified tree on feat/x. Yields
  # [hub_dir, projects_dir, branch_tree].
  def with_cross_repo_world
    Dir.mktmpdir do |raw|
      projects = File.realpath(raw)

      # The hub — the reviewer's standing checkout. Deliberately has no feat/x.
      hub = File.join(projects, "mcritchie-studio")
      FileUtils.mkdir_p(hub)
      git!(hub, "init", "-q")
      git!(hub, "config", "user.email", "t@t.co")
      git!(hub, "config", "user.name", "T")
      write(hub, "README.md", "hub\n")
      git!(hub, "add", "-A")
      git!(hub, "commit", "-qm", "hub init")

      # The satellite's task worktree — a real repo at the path the worktree glob finds.
      wt = File.join(projects, "satellite-app", ".worktrees", "root-reviewer-dor-check-fingerprint")
      FileUtils.mkdir_p(wt)
      git!(wt, "init", "-q")
      git!(wt, "config", "user.email", "t@t.co")
      git!(wt, "config", "user.name", "T")
      write(wt, "README.md", "satellite\n")
      git!(wt, "add", "-A")
      git!(wt, "commit", "-qm", "init")
      # The `origin` a real clone has, pointing at the SAME repo as the task's
      # pr_url (github.com/x/y). Since 2026-08-09 the rooting validates a candidate
      # worktree's REPO as well as its branch, and it asks `origin` first — so a
      # fixture with no remote at all was describing a world where the PR lives in
      # one repo and the task's tree belongs to no repo, which cannot happen.
      git!(wt, "remote", "add", "origin", "https://github.com/x/y.git")
      git!(wt, "checkout", "-q", "-b", "feat/x")
      write(wt, "app/services/widget.rb", "class Widget; end\n")
      git!(wt, "add", "-A")
      git!(wt, "commit", "-qm", "feat")
      branch_tree = git_out(wt, "rev-parse", "feat/x^{tree}")
      git!(wt, "update-ref", "refs/remotes/origin/feat/x", "feat/x")

      yield hub, projects, branch_tree
    end
  end

  # ── env + runner ───────────────────────────────────────────────────────────

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, [ENV.key?(k), ENV[k]]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, (had, val)| had ? ENV[k] = val : ENV.delete(k) }
  end

  # A backend task fixture whose spec + tiers are all satisfied, so the ONLY thing
  # under test is the suite-fingerprint rooting. checks_run carries the fast-cert
  # evidence line for `fp` (the tree the builder certified). pr_url present so the
  # CI gate has a target (paired with DOR_CHECK_CI_STATUS=green).
  def task_json(fp)
    {
      "slug" => "root-reviewer-dor-check-fingerprint",
      "title" => "Root reviewer dor-check fingerprint",
      "metadata" => { "devops" => {
        "kind" => "bug",
        "shape" => "backend",
        "branch" => "feat/x",
        "pr_url" => "https://github.com/x/y/pull/1",
        "acceptance" => ["roots fingerprint at branch"],
        "repositories" => ["mcritchie-studio"],
        "risk_tags" => ["devops"],
        "test_plan" => ["[unit] review roots at branch tree"],
        "checks_run" => [
          "[unit] bin/rails test test/lib/dor_check_review_fingerprint_test.rb",
          "[integration] dor-check --gate-role review end-to-end",
          "[fast-cert@#{fp}] diff-mapped tests + spine + scoped rubocop"
        ]
      } }
    }
  end

  # Shell bin/dor-check --file with the given git root + env, returning the parsed
  # --json verdict. DOR_CHECK_SUITE_EVIDENCE is forced OFF so the REAL fingerprint
  # path runs; the diff root is the temp repo; CI is injected green.
  def review_check(task, root, *args, ci: "green", projects_dir: nil)
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task))
      env = {
        "DOR_CHECK_DIFF_ROOT" => root,
        "DOR_CHECK_PROJECTS_DIR" => projects_dir,
        "DOR_CHECK_SUITE_EVIDENCE" => nil,
        "DOR_CHECK_CHANGED_FILES" => nil,
        "DOR_CHECK_DIFF_BASE" => nil,
        "DOR_CHECK_CI_STATUS" => ci
      }
      out = nil
      with_env(env) do
        out = IO.popen(SessionEnv.neutralized, "#{BIN} --file #{path} --json #{args.join(' ')} 2>/dev/null", &:read)
      end
      [JSON.parse(out), $?.exitstatus]
    end
  end

  # ── [unit] FullSuiteGate.fingerprint_of_ref ────────────────────────────────

  def test_unit_fingerprint_of_ref_matches_the_branch_committed_tree
    with_reviewer_repo do |dir, _base, branch_tree|
      # Content-addressed: the branch's ^{tree} equals the tree the builder would
      # have fingerprinted with a working tree ON the branch — reachable from the
      # BASE checkout where the reviewer actually stands.
      assert_equal branch_tree, FullSuiteGate.fingerprint_of_ref(dir, "origin/feat/x")
      assert_equal branch_tree, FullSuiteGate.fingerprint_of_ref(dir, "feat/x")
      # And it is NOT the primary working tree — the whole point of the fix.
      refute_equal FullSuiteGate.fingerprint(dir), branch_tree,
                   "the primary checkout's working tree must differ from the branch tree"
    end
  end

  def test_unit_fingerprint_of_ref_is_nil_for_an_unresolvable_ref
    with_reviewer_repo do |dir, _base, _tree|
      assert_nil FullSuiteGate.fingerprint_of_ref(dir, "origin/feat/does-not-exist")
    end
  end

  def test_unit_fingerprint_of_ref_is_nil_for_a_blank_ref
    with_reviewer_repo do |dir, _base, _tree|
      assert_nil FullSuiteGate.fingerprint_of_ref(dir, "")
      assert_nil FullSuiteGate.fingerprint_of_ref(dir, "   ")
    end
  end

  # ── [integration] the review-role rooting through bin/dor-check ─────────────

  def test_integration_review_role_roots_fingerprint_at_branch_tree_not_primary
    with_reviewer_repo do |dir, _base, branch_tree|
      primary_tree = FullSuiteGate.fingerprint(dir)
      verdict, code = review_check(task_json(branch_tree), dir, "--gate-role", "review")

      assert_equal 0, code, "review gate-zero should PASS a fast cert rooted at the branch tree"
      assert verdict["ready"], "expected ready=true, got errors: #{verdict['errors']}"
      assert_equal "fast", verdict.dig("full_suite", "route")
      assert_equal branch_tree, verdict.dig("full_suite", "fingerprint"),
                   "review role must fingerprint the TASK BRANCH tree"
      refute_equal primary_tree, verdict.dig("full_suite", "fingerprint"),
                   "review role must NOT fingerprint the reviewer's primary working tree"
    end
  end

  # ── CROSS-REPO: the reviewer stands in a DIFFERENT repo than the task ──────
  #
  # The 2026-07-09 fix above solved the SAME-REPO case: a reviewer on release/main
  # in the task's own repo now roots the fingerprint at the branch tree. It does not
  # reach the cross-repo case, which is the NORMAL one — Carl's pr-review SOP says to
  # run review FROM the mcritchie-studio primary checkout, while most PRs are in
  # turf-monster or studio-engine. There, `origin/feat/x` does not resolve in the
  # standing repo at all, review_fingerprint returns nil, and the gate falls back to
  # hashing the HUB's working tree — which can never equal a satellite's certified
  # tree, so a perfectly fresh cert reads STALE. Observed 2026-07-28: it burned a
  # gate attempt and left a real dor_review #1 FAILED row on a turf-monster task.
  def test_integration_review_role_roots_at_the_tasks_own_repo_across_repos
    with_cross_repo_world do |hub_dir, projects_dir, branch_tree|
      hub_tree = FullSuiteGate.fingerprint(hub_dir)
      task = task_json(branch_tree)
      task["metadata"]["devops"]["repositories"] = ["satellite-app"]
      task["metadata"]["devops"]["worktree_slug"] = "root-reviewer-dor-check-fingerprint"

      verdict, code = review_check(task, hub_dir, "--gate-role", "review",
                                   projects_dir: projects_dir)

      assert_equal 0, code,
                   "a fresh cert on a SATELLITE task must not read STALE just because the reviewer " \
                   "stands in the hub: #{verdict['errors']}"
      assert verdict["ready"], "expected ready=true, got errors: #{verdict['errors']}"
      assert_equal branch_tree, verdict.dig("full_suite", "fingerprint"),
                   "must fingerprint the TASK's tree in its own repo"
      refute_equal hub_tree, verdict.dig("full_suite", "fingerprint"),
                   "must NOT fingerprint the reviewer's hub working tree"
    end
  end

  def test_integration_review_role_falls_back_to_local_branch_when_origin_absent
    with_reviewer_repo(with_origin: false) do |dir, _base, branch_tree|
      verdict, code = review_check(task_json(branch_tree), dir, "--gate-role", "review")

      assert_equal 0, code
      assert verdict["ready"], "local feat/x must satisfy the rooting when origin/feat/x is unfetched"
      assert_equal branch_tree, verdict.dig("full_suite", "fingerprint")
    end
  end

  # An EXPLICIT root is the caller's declaration, and it still wins — even when it
  # points at a tree that isn't the task's. review_check always sets
  # DOR_CHECK_DIFF_ROOT, so this run grades that root's working tree and the cert
  # reads STALE.
  #
  # This is NOT the builder lane's production behavior any more. An IMPLICIT root
  # (the real path: an agent standing in the primary, no override) used to land here
  # too — a false STALE for a perfectly fresh cert, 6 of 6 tasks on 2026-07-14 — and
  # is now caught by the task-root guard, which re-roots at the task's tree and says
  # so. See test/lib/dor_check_root_guard_test.rb. What survives here is only the
  # narrow, correct rule the cert writers share: DECLARE a root and you own it.
  def test_integration_an_explicitly_declared_foreign_root_is_still_graded_as_asked
    with_reviewer_repo do |dir, _base, branch_tree|
      primary_tree = FullSuiteGate.fingerprint(dir)
      verdict, code = review_check(task_json(branch_tree), dir) # builder role (default)

      assert_equal 1, code, "an explicitly declared non-branch root grades that root — cert reads STALE"
      refute verdict["ready"]
      assert_equal primary_tree, verdict.dig("full_suite", "fingerprint"),
                   "DOR_CHECK_DIFF_ROOT wins over the guard, exactly as FAST_CHECK_ROOT does"
      assert_nil verdict.dig("full_suite", "route")
    end
  end

  # ── [integration] THE PROVENANCE INVARIANT ─────────────────────────────────
  #
  #     The root NAMED in a fingerprint message is the root that was HASHED
  #     to produce it.
  #
  # Stated positively, and checked by RECOMPUTING: take the root the gate names,
  # hash it the way the gate says it hashed it, and you must get the fingerprint the
  # gate printed. Not "diff_root is usually right" — no third number, ever.
  #
  # The bug this kills: the message unconditionally printed diff_root. In the review
  # lane the fingerprint ALWAYS comes from the branch tree (that IS the fix in this
  # file), while diff_root is the reviewer's PRIMARY checkout — which was never
  # hashed and hashes to something else entirely. So the gate printed a precise hash
  # beside a root that could not have produced it, in the one lane whose verdict is
  # authoritative. A confident wrong root is worse than the opaque STALE it replaced:
  # the opaque one sent you nowhere, this one sends you somewhere WRONG.

  # Recompute the fingerprint from the provenance the verdict itself declares, and
  # assert it comes back identical. `repo` is only used to catch a gate that fails to
  # declare its repo at all.
  def assert_fingerprint_recomputes_from_its_named_root(verdict, repo)
    fs = verdict["full_suite"]
    refute_nil fs, "no full_suite block — nothing was graded"
    printed = fs["fingerprint"]
    named = fs["fingerprint_root"]
    source = fs["fingerprint_source"]
    refute_nil printed, "a graded verdict must carry the fingerprint it graded"
    refute_nil named, "a fingerprint with no declared root is a number nobody can check"

    recomputed =
      case source
      when "branch-tree"
        assert_equal repo, fs["fingerprint_repo"], "a ref is only resolvable inside a named repo"
        git_out(fs["fingerprint_repo"], "rev-parse", named)
      when "working-tree" then FullSuiteGate.fingerprint(named)
      else flunk "unknown fingerprint_source #{source.inspect}"
      end

    assert_equal printed, recomputed,
                 "THE INVARIANT: the root the gate NAMES (#{named}, #{source}) must be the root it HASHED. " \
                 "Recomputing it gave #{recomputed.inspect}, but the gate printed #{printed.inspect} — a third number."
    fs
  end

  # The review lane, where the override is UNCONDITIONAL. A stale cert forces the
  # reporting path (the message + the JSON provenance) to actually render.
  def test_integration_review_lane_names_the_branch_tree_it_hashed_not_the_reviewers_root
    with_reviewer_repo do |dir, _base, branch_tree|
      primary_tree = FullSuiteGate.fingerprint(dir) # the THIRD number: never hashed for this verdict
      refute_equal branch_tree, primary_tree, "fixture must distinguish the two trees or this proves nothing"

      stale_cert = "0" * 40
      verdict, code = review_check(task_json(stale_cert), dir, "--gate-role", "review")
      assert_equal 1, code, "a stale cert must still refuse — this test needs the STALE message rendered"

      fs = assert_fingerprint_recomputes_from_its_named_root(verdict, dir)
      assert_equal FullSuiteGate::BRANCH_TREE_SOURCE, fs["fingerprint_source"]
      assert_equal branch_tree, fs["fingerprint"]
      assert_equal "origin/feat/x^{tree}", fs["fingerprint_root"],
                   "the review lane hashed the branch tree, so THAT is what it must name"
      refute_equal dir, fs["fingerprint_root"], "naming the reviewer's primary checkout is the bug"

      blame = verdict["errors"].join(" ")
      assert_includes blame, "origin/feat/x^{tree}", "the message must name the ref it hashed"
      refute_includes blame, "(root: #{dir})", "the old lie: diff_root printed as the fingerprint's root"
      refute_includes blame, primary_tree[0, 12],
                      "the primary's own tree hash must appear NOWHERE — it graded nothing"
    end
  end

  # The non-override half of the same invariant: no override → the working tree at
  # the declared root IS what was hashed, so that is what gets named. Same assertion,
  # opposite branch — the invariant holds over BOTH paths or it holds over neither.
  def test_integration_working_tree_lane_names_the_root_it_hashed
    with_reviewer_repo do |dir, _base, branch_tree|
      verdict, code = review_check(task_json(branch_tree), dir) # builder role: no override
      assert_equal 1, code, "the declared root's working tree is not the branch tree → STALE"

      fs = assert_fingerprint_recomputes_from_its_named_root(verdict, dir)
      assert_equal FullSuiteGate::WORKING_TREE_SOURCE, fs["fingerprint_source"]
      assert_equal dir, fs["fingerprint_root"], "no override → the root it hashed is the root it names"

      blame = verdict["errors"].join(" ")
      assert_includes blame, dir
      refute_includes blame, "HEAD is now",
                      "the fingerprint is the as-if-committed tree, NOT HEAD^{tree} — an agent who " \
                      "verifies 'HEAD' by hand gets a different hash and concludes the tool is broken"
    end
  end

  # A fingerprint with no provenance cannot be announced honestly, so the gate module
  # refuses to grade one. This is what makes the invariant STRUCTURAL rather than a
  # convention every future caller has to remember.
  def test_unit_evaluate_refuses_an_override_with_no_provenance
    with_reviewer_repo do |dir, _base, branch_tree|
      err = assert_raises(ArgumentError) do
        FullSuiteGate.evaluate(checks: ["[full-suite@#{branch_tree}] x"], root: dir,
                               fingerprint_override: branch_tree)
      end
      assert_match(/provenance|fingerprint_origin/i, err.message)
    end
  end

  def test_unit_evaluate_records_the_ref_it_hashed_as_the_fingerprint_root
    with_reviewer_repo do |dir, _base, branch_tree|
      origin = FullSuiteGate.fingerprint_of_first_ref(dir, "origin/feat/x", "feat/x")
      assert_equal branch_tree, origin[:fingerprint]
      assert_equal "origin/feat/x^{tree}", origin[:ref], "the hash and the ref that produced it travel together"

      verdict = FullSuiteGate.evaluate(checks: ["[full-suite@#{branch_tree}] x"], root: dir,
                                       fingerprint_override: origin[:fingerprint], fingerprint_origin: origin)
      assert_equal branch_tree, verdict[:fingerprint]
      assert_equal "origin/feat/x^{tree}", verdict[:fingerprint_root]
      assert_equal dir, verdict[:fingerprint_repo]
      assert_equal FullSuiteGate::BRANCH_TREE_SOURCE, verdict[:fingerprint_source]
      refute_equal dir, verdict[:fingerprint_root], "root is NOT the provenance when an override is in play"
    end
  end

  # The debug/resolver seam mirrors the gate: --suite-fingerprint --gate-role
  # review prints the BRANCH tree so a reviewer can eyeball it against a
  # [fast-cert@<fp>] line, instead of the misleading primary working-tree hash.
  def test_integration_suite_fingerprint_seam_review_role_prints_branch_tree
    with_reviewer_repo do |dir, _base, branch_tree|
      env = { "DOR_CHECK_DIFF_ROOT" => dir, "DOR_CHECK_SUITE_EVIDENCE" => nil }
      # The seam has no task fetch, so it derives the branch feat/<slug> from the
      # positional arg — pass "x" so it resolves feat/x, the fixture branch.
      out = nil
      with_env(env) do
        out = IO.popen(SessionEnv.neutralized, "#{BIN} x --suite-fingerprint --gate-role review 2>/dev/null", &:read).strip
      end
      assert_equal branch_tree, out
      refute_equal FullSuiteGate.fingerprint(dir), out
    end
  end
end
