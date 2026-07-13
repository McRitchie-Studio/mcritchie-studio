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
  def review_check(task, root, *args, ci: "green")
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task))
      env = {
        "DOR_CHECK_DIFF_ROOT" => root,
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

  def test_integration_review_role_falls_back_to_local_branch_when_origin_absent
    with_reviewer_repo(with_origin: false) do |dir, _base, branch_tree|
      verdict, code = review_check(task_json(branch_tree), dir, "--gate-role", "review")

      assert_equal 0, code
      assert verdict["ready"], "local feat/x must satisfy the rooting when origin/feat/x is unfetched"
      assert_equal branch_tree, verdict.dig("full_suite", "fingerprint")
    end
  end

  # The bug, reproduced: the SAME fast cert, graded from the SAME primary checkout
  # WITHOUT the review rooting (builder role), fingerprints the working tree — a
  # different tree — so the cert reads STALE and the gate refuses. This is exactly
  # what reviewers hit; the review role above is the fix.
  def test_integration_builder_role_fingerprints_the_working_tree_false_stale
    with_reviewer_repo do |dir, _base, branch_tree|
      primary_tree = FullSuiteGate.fingerprint(dir)
      verdict, code = review_check(task_json(branch_tree), dir) # builder role (default)

      assert_equal 1, code, "builder role from a non-branch checkout reads the fast cert STALE"
      refute verdict["ready"]
      assert_equal primary_tree, verdict.dig("full_suite", "fingerprint"),
                   "builder role stays rooted at the cwd working tree (unchanged)"
      assert_nil verdict.dig("full_suite", "route")
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
