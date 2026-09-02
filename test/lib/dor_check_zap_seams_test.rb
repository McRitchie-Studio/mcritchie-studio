# frozen_string_literal: true

# [integration] The reviewer-zap seams, at the GATE (/tasks/reviewer-zap-has-unmapped-seams).
#   ruby -Itest test/lib/dor_check_zap_seams_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# test/lib/review_tree_guard_test.rb proves the CLASSIFIER answers correctly. This file
# proves bin/dor-check ASKS it and acts on the answer — the pairing that matters, since
# a correct guard wired to nothing is the failure mode worth more than either half. It
# is the same split as test_only_diff_test.rb (classifier) vs dor_check_test.rb (gate).
#
# THE TWO SEVERITIES ARE THE SUBJECT, not an implementation detail, and both directions
# are pinned below:
#   seam 1 (graded tree ≠ PR head)  REFUSES — a mismatch can only be a false refusal,
#                                   never a false pass, and its remedy is a fetch.
#   seam 2 (the base has moved)     REPORTS — `accepted` moves constantly, and refusing
#                                   every review whose base gained a commit would wedge
#                                   the lane for a fact that is usually harmless.
# Flip either one and a test here goes red, which is the point: the choice was argued,
# so it should not be changeable by accident.
#
# SEAM 3 IS DELIBERATELY ABSENT. A reviewer zap was believed to demote a task out of
# `submitted`; that was FALSIFIED (turf #518 took a zap and stayed `submitted`, breaker
# clear), and what moved #513 is still unidentified. Nothing here encodes a demotion
# mechanism, and nothing should until someone measures one.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class DorCheckZapSeamsTest < Minitest::Test
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

  # A BUILDER'S DESK, which is what `--gate-role review` re-roots to: on feat/x, with
  # refs/remotes/origin/feat/x pointing where the builder last pushed. A reviewer's zap
  # pushed from ANOTHER checkout does not move that ref — which is the seam, so the
  # fixture models it by simply never moving it.
  #
  # `origin/accepted` is a real ref here so the base re-derivation has something to
  # read. `base_moved: true` advances it past the branch, reproducing turf #517 merging
  # while #519's checks were still running.
  def with_desk(base_moved: false)
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      git!(dir, "init", "-q")
      git!(dir, "config", "user.email", "t@t.co")
      git!(dir, "config", "user.name", "T")
      write(dir, "README.md", "base\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "init")
      git!(dir, "branch", "-M", "accepted")
      git!(dir, "update-ref", "refs/remotes/origin/accepted", "accepted")

      git!(dir, "checkout", "-q", "-b", "feat/x")
      write(dir, "app/services/widget.rb", "class Widget; end\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "feat")
      git!(dir, "update-ref", "refs/remotes/origin/feat/x", "feat/x")
      desk_head = git_out(dir, "rev-parse", "feat/x")

      if base_moved
        # Another PR merges into `accepted` mid-review — and touches the very file the
        # e2e declared-set contract lives in, exactly as turf #517 did.
        git!(dir, "checkout", "-q", "accepted")
        write(dir, "config/e2e_lane.yml", "executed: 205\n")
        git!(dir, "add", "-A")
        git!(dir, "commit", "-qm", "another PR merges")
        git!(dir, "update-ref", "refs/remotes/origin/accepted", "accepted")
        git!(dir, "checkout", "-q", "feat/x")
      end

      yield dir, desk_head
    end
  end

  def with_env(vars)
    saved = vars.keys.to_h { |k| [k, [ENV.key?(k), ENV[k]]] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    saved.each { |k, (had, val)| had ? ENV[k] = val : ENV.delete(k) }
  end

  # A backend task whose spec, tiers and cert are ALL satisfied, so the only thing that
  # can move the verdict is the zap guard under test.
  def task_json
    {
      "slug" => "zap-seams",
      "title" => "Zap seams",
      "metadata" => { "devops" => {
        "kind" => "bug", "shape" => "backend", "branch" => "feat/x",
        "pr_url" => "https://github.com/x/y/pull/1",
        "acceptance" => ["review grades the merging tree"],
        "repositories" => ["mcritchie-studio"], "risk_tags" => ["devops"],
        "test_plan" => ["[unit] guard", "[integration] gate"],
        "post_deploy_cmd" => "none",
        "checks_run" => ["[unit] a", "[integration] b"]
      } }
    }
  end

  # Shell bin/dor-check --file against the desk. `pr_head` is injected through
  # DOR_CHECK_PR_HEAD (the seam mirroring DOR_CHECK_CI_STATUS) so these tests never
  # reach GitHub for a headRefOid.
  def check(root, pr_head:, review: true, changed: "app/services/widget.rb")
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task_json))
      env = {
        "DOR_CHECK_DIFF_ROOT" => root,
        "DOR_CHECK_DIFF_BASE" => "accepted",
        "DOR_CHECK_CHANGED_FILES" => changed,
        "DOR_CHECK_SUITE_EVIDENCE" => "ok",
        "DOR_CHECK_PR_FILES" => "",
        "DOR_CHECK_CI_STATUS" => "green",
        "DOR_CHECK_PR_HEAD" => pr_head,
        "DOR_BASE_BRANCH" => "accepted"
      }
      role = review ? "--gate-role review" : ""
      out = nil
      with_env(env) do
        out = IO.popen(SessionEnv.neutralized, "#{BIN} --file #{path} --json #{role} 2>/dev/null", &:read)
      end
      [JSON.parse(out), $?.exitstatus]
    end
  end

  def errors_of(verdict) = Array(verdict["errors"]).join(" | ")
  def suggestions_of(verdict) = Array(verdict["suggestions"]).join(" | ")

  # ==== SEAM 1 — the gate must not grade a pre-zap tree ==========================

  # THE SEAM. The reviewer zapped from elsewhere, so the desk's origin/feat/x is still
  # at the pre-zap commit while the PR head has moved. Before this guard, the verdict
  # read clean: the cert fingerprint hashes that very ref, so it matched, and nothing
  # else compared the two.
  def test_integration_review_refuses_when_the_desk_is_behind_the_pr_head
    with_desk do |dir, desk_head|
      zapped = "9137d57ac0ffee1234567890abcdef1234567890"
      refute_equal desk_head, zapped, "fixture: the two commits must differ or this proves nothing"

      verdict, code = check(dir, pr_head: zapped)

      refute_equal 0, code,
                   "a review gate whose tree is one commit behind the PR head returned READY — the verdict " \
                   "describes a tree that is not the one merging\n#{verdict.inspect}"
      assert_match(/NOT the PR head/, errors_of(verdict))
      assert_match(/#{desk_head[0, 12]}/, errors_of(verdict),
                   "the refusal must name the commit it actually graded")
      assert_match(/#{zapped[0, 12]}/, errors_of(verdict),
                   "…and the PR head it was measured against, so a reviewer can verify by hand")
      assert_match(/git fetch origin feat\/x/, errors_of(verdict),
                   "a refusal whose remedy is one command must print that command")
    end
  end

  # The ordinary review — nobody pushed after the builder — must stay clean, or the
  # guard is a tax on every review rather than a check on a rare event.
  def test_integration_review_passes_when_the_desk_is_at_the_pr_head
    with_desk do |dir, desk_head|
      verdict, code = check(dir, pr_head: desk_head)

      assert_equal 0, code, verdict.inspect
      refute_match(/NOT the PR head/, errors_of(verdict))
    end
  end

  # gh and git print SHAs at different widths; an abbreviated head is the same commit.
  def test_integration_an_abbreviated_pr_head_is_not_a_false_mismatch
    with_desk do |dir, desk_head|
      verdict, code = check(dir, pr_head: desk_head[0, 7])

      assert_equal 0, code, verdict.inspect
    end
  end

  # BUILDER-SIDE IS UNTOUCHED. At submit the PR head legitimately moves ahead of a
  # local tree mid-push, and this gate has no business refusing there — the guard is
  # about the REVIEW verdict, which is the one that merges.
  def test_integration_the_builder_gate_does_not_refuse_a_moved_pr_head
    with_desk do |dir|
      verdict, code = check(dir, pr_head: "9137d57ac0ffee1234567890abcdef1234567890", review: false)

      assert_equal 0, code, verdict.inspect
      refute_match(/NOT the PR head/, errors_of(verdict))
    end
  end

  # A check that could not run must SAY it did not, rather than passing in silence —
  # the same principle the docs-shape waiver line landed on.
  def test_integration_a_missing_pr_head_names_the_unmade_check
    with_desk do |dir|
      verdict, code = check(dir, pr_head: "")

      assert_equal 0, code, "an unaskable question is not a failure#{verdict.inspect}"
      assert_match(/could not confirm the graded tree IS the PR head/, suggestions_of(verdict))
    end
  end

  # ==== SEAM 2 — the base moving out from under a finished check ================

  # turf #517 merging 97 seconds after #519's declared-set check finished. The gate
  # REPORTS it, names the consequence for the e2e declared/executed set, and does NOT
  # refuse.
  def test_integration_review_reports_a_base_that_moved_without_refusing
    with_desk(base_moved: true) do |dir, desk_head|
      verdict, code = check(dir, pr_head: desk_head)

      assert_equal 0, code,
                   "a moved base must not REFUSE — `accepted` moves constantly, and blocking every review " \
                   "after any merge would wedge the lane for a usually-harmless fact\n#{verdict.inspect}"
      assert_match(/base has MOVED/, suggestions_of(verdict))
      assert_match(/DECLARED-vs-EXECUTED/, suggestions_of(verdict),
                   "the report must name the check the movement invalidates, or a reviewer cannot act on it")
      assert_match(/1 commit\(s\) ahead/, suggestions_of(verdict))
    end
  end

  # No movement → no line. A report that fires on every review is noise, and noise is
  # how a real finding gets skipped.
  def test_integration_no_base_report_when_the_base_has_not_moved
    with_desk do |dir, desk_head|
      verdict, code = check(dir, pr_head: desk_head)

      assert_equal 0, code, verdict.inspect
      refute_match(/base has MOVED/, suggestions_of(verdict))
    end
  end

  # The base report is REVIEW-role only: a builder rebases as a matter of course, and
  # this line would be noise on every submit.
  def test_integration_the_builder_gate_does_not_report_base_movement
    with_desk(base_moved: true) do |dir, desk_head|
      verdict, _code = check(dir, pr_head: desk_head, review: false)

      refute_match(/base has MOVED/, suggestions_of(verdict))
    end
  end
end
