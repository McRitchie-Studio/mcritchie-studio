# frozen_string_literal: true

# [integration] THE GREEN THAT COULD NOT HAVE COVERED THE MERGE
# (/tasks/gate-credits-a-stale-green).
#   ruby -Itest test/lib/dor_check_base_movement_test.rb
# Also picked up by the normal `bin/rails test` sweep.
#
# test/lib/base_movement_audit_test.rb proves the CLASSIFIER answers correctly. This
# file proves bin/dor-check ASKS it and ACTS on the answer — the same split as
# review_tree_guard_test.rb (classifier) vs dor_check_zap_seams_test.rb (gate), and for
# the same reason: a correct guard wired to nothing is the failure mode worth more than
# either half.
#
# ── THE HOLE ────────────────────────────────────────────────────────────────────
#
# A PR's CI runs against the base AS IT STOOD when the run started, and ci.yml triggers
# on pull_request and on pushes to main/release ONLY — so a merge into `accepted` moves
# the base and re-runs NOTHING. If `accepted` advances after the run, THE GREEN NEVER
# COVERED THE MERGE, and `--gate-role review` credited it anyway.
#
# MEASURED, not theorised (Carl, PR #1258, 2026-09-07): the `accepted` tip was committed
# at 07:59:02Z, THREE POINT THREE MINUTES AFTER that PR's CI completed at 07:55:44Z. The
# commit it carried changed test/lib/dor_check_exempt_ci_test.rb by +117/-17 — the very
# guard that PR's design depended on. A 12/12 green said nothing whatever about that
# combination. It came out safe only because a reviewer built the merge preview by hand
# and ran the family: 24 green / 0 red.
#
# ── WHY SEAM 2 IS NOT ALREADY THIS ──────────────────────────────────────────────
#
# dor-check already REPORTS that the base moved (ReviewTreeGuard.base_assessment), and
# reviewers satisfy that report by arguing FILE DISJOINTNESS — "the N commits `accepted`
# gained touch none of my files." That argument is cheap and usually right. It is NOT
# the claim "the merged tree is green", and it fails in exactly one shape: when a base
# commit changes a SHARED GUARD rather than a shared source file. Disjointness is then
# TRUE and IRRELEVANT — the base touched no file this PR changes, and still changed a
# test that grades it.
#
# THE TWO CLAIMS ARE KEPT APART ON PURPOSE, here and in the verdict text. Collapsing
# them is the defect one level down.
#
# ── THE THREE CASES THIS FILE PINS ──────────────────────────────────────────────
#
#   shared guard, base commit AFTER the run   REFUSES  — disjointness cannot settle it
#   disjoint,     base commit AFTER the run   REPORTS  — the busy-night case, unharmed
#   shared guard, base commit BEFORE the run  REPORTS  — the run DID cover it
#
# The third is the control: it differs from the first ONLY in the commit's timestamp, so
# a gate that ignored the clock (or never read it) would refuse it too and go red here.
# Without that row the refusal could be firing on the guard overlap alone and this file
# would never notice.

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require_relative "../support/session_env"

class DorCheckBaseMovementTest < Minitest::Test
  BIN = File.expand_path("../../bin/dor-check", __dir__)

  # The measured clock from PR #1258, reused so the fixture and the incident share
  # numbers a reader can line up against the task record.
  CI_DONE     = "2026-09-07T07:55:44Z"
  AFTER_RUN   = "2026-09-07T07:59:02Z" # 3.3 minutes later — the incident
  BEFORE_RUN  = "2026-09-07T07:50:00Z" # inside the run's coverage

  # ── git fixture ────────────────────────────────────────────────────────────

  def git!(dir, *args, at: nil)
    env = at ? { "GIT_AUTHOR_DATE" => at, "GIT_COMMITTER_DATE" => at } : {}
    assert system(env, "git", "-C", dir, *args, out: File::NULL, err: File::NULL),
           "git #{args.join(' ')}"
  end

  def write(dir, rel, body)
    full = File.join(dir, rel)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, body)
  end

  # A builder's desk carrying a TOOL and its harness test FAMILY — the shape
  # FastCert.family_tests maps: bin/widget-tool → test/lib/widget_tool_test.rb plus its
  # widget_tool_<aspect>_test.rb siblings. That is the real repo's bin/dor-check →
  # test/lib/dor_check_exempt_ci_test.rb relationship, which is the one that broke.
  #
  # `base_change` is the file the LATER merge into `accepted` touches, and `at` is when
  # it lands. The PR itself only ever changes bin/widget-tool, so file disjointness
  # holds in EVERY case below — that is the whole point.
  def with_desk(base_change:, at:)
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      git!(dir, "init", "-q")
      git!(dir, "config", "user.email", "t@t.co")
      git!(dir, "config", "user.name", "T")

      write(dir, "bin/widget-tool", "#!/usr/bin/env ruby\n# the tool under review\n")
      write(dir, "test/lib/widget_tool_test.rb", "# the twin\n")
      write(dir, "test/lib/widget_tool_exempt_test.rb", "# the FAMILY guard\n")
      write(dir, "docs/unrelated.md", "prose\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "init", at: BEFORE_RUN)
      git!(dir, "branch", "-M", "accepted")
      git!(dir, "update-ref", "refs/remotes/origin/accepted", "accepted")

      # The PR: it changes the TOOL and nothing else.
      git!(dir, "checkout", "-q", "-b", "feat/x")
      write(dir, "bin/widget-tool", "#!/usr/bin/env ruby\n# the tool, edited\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "feat", at: BEFORE_RUN)
      git!(dir, "update-ref", "refs/remotes/origin/feat/x", "feat/x")
      desk_head = IO.popen(["git", "-C", dir, "rev-parse", "feat/x"], &:read).to_s.strip

      # Another PR merges into `accepted`. `at` decides whether this PR's CI could
      # possibly have seen it.
      git!(dir, "checkout", "-q", "accepted")
      write(dir, base_change, "# changed by the merge that moved the base\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "another PR merges", at: at)
      git!(dir, "update-ref", "refs/remotes/origin/accepted", "accepted")
      base_sha = IO.popen(["git", "-C", dir, "rev-parse", "accepted"], &:read).to_s.strip
      git!(dir, "checkout", "-q", "feat/x")

      yield dir, desk_head, base_sha
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
  # can move the verdict is the base-movement guard under test.
  def task_json(multi_repo: false)
    extra = multi_repo ? { "pr_urls" => { "mcritchie-studio" => "https://github.com/x/y/pull/1",
                                          "studio-engine" => "https://github.com/x/z/pull/2" } } : {}
    {
      "slug" => "base-movement",
      "title" => "Base movement",
      "metadata" => { "devops" => {
        "kind" => "bug", "shape" => "backend", "branch" => "feat/x",
        "pr_url" => "https://github.com/x/y/pull/1",
        "acceptance" => ["the green must be about this merge"],
        "repositories" => ["mcritchie-studio"], "risk_tags" => ["devops"],
        "test_plan" => ["[unit] guard", "[integration] gate"],
        "post_deploy_cmd" => "none",
        "checks_run" => ["[unit] a", "[integration] b"]
      }.merge(extra) }
    }
  end

  def check(root, desk_head, ci_completed_at: CI_DONE, review: true, multi_repo: false)
    Dir.mktmpdir do |d|
      path = File.join(d, "task.json")
      File.write(path, JSON.generate(task_json(multi_repo: multi_repo)))
      env = {
        "DOR_CHECK_DIFF_ROOT" => root,
        "DOR_CHECK_DIFF_BASE" => "accepted",
        "DOR_CHECK_CHANGED_FILES" => "bin/widget-tool",
        "DOR_CHECK_SUITE_EVIDENCE" => "ok",
        "DOR_CHECK_PR_FILES" => "",
        "DOR_CHECK_CI_STATUS" => "green",
        "DOR_CHECK_CI_COMPLETED_AT" => ci_completed_at,
        "DOR_CHECK_PR_HEAD" => desk_head,
        "DOR_BASE_BRANCH" => "accepted",
        "DOR_CHECK_CI_STATUS_BY_REPO" =>
          (multi_repo ? JSON.generate({ "mcritchie-studio" => "green", "studio-engine" => "green" }) : nil)
      }.compact
      role = review ? "--gate-role review" : ""
      out = nil
      with_env(env) do
        out = IO.popen(SessionEnv.neutralized, "#{BIN} --file #{path} --json #{role} 2>/dev/null", &:read)
      end
      [JSON.parse(out), $?.exitstatus]
    end
  end

  def errors_of(v) = Array(v["errors"]).join(" | ")
  def suggestions_of(v) = Array(v["suggestions"]).join(" | ")
  def all_of(v) = "#{errors_of(v)} | #{suggestions_of(v)}"

  # ==== THE HOLE ITSELF =========================================================

  # THE INCIDENT, reproduced. `accepted` gained a commit 3.3 minutes AFTER the run
  # finished, and that commit changed the PR's FAMILY GUARD — a test that grades
  # bin/widget-tool without being a file bin/widget-tool's PR touches.
  #
  # Before this guard the verdict was READY: CI green, disjointness true, seam 2's
  # report present but unarguable-with. That is a green describing a tree nobody will
  # ever merge.
  def test_integration_review_refuses_a_green_a_later_guard_change_invalidated
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head, base_sha|
      verdict, code = check(dir, head)

      refute_equal 0, code,
                   "the review gate returned READY on a green that COMPLETED BEFORE the base gained a " \
                   "commit changing this PR's own test family — the green describes a tree that will " \
                   "never be merged\n#{verdict.inspect}"
      assert_match(/test\/lib\/widget_tool_exempt_test\.rb/, errors_of(verdict),
                   "the refusal must NAME the guard that moved, or a reviewer cannot check it by hand")
      assert_match(/bin\/widget-tool/, errors_of(verdict),
                   "…and the file of this PR's that the guard grades")
      assert_match(/#{base_sha[0, 12]}/, errors_of(verdict),
                   "…and the base commit that carried it")
      assert_match(/07:59:02/, errors_of(verdict), "…and when it landed")
      assert_match(/07:55:44/, errors_of(verdict), "…against when the run finished")
      assert_match(/disjoint/i, errors_of(verdict),
                   "the refusal must say WHY the file-disjointness argument does not settle it — " \
                   "that argument is what reviewers reach for here, and it is true and irrelevant")
    end
  end

  # ==== PROVE THE NEGATIVE — the busy night must not get worse ===================

  # `accepted` moves constantly. A base commit that lands after the run but touches
  # NOTHING this PR's tests reach is the ordinary case, and refusing it would wedge the
  # lane for a fact that is usually harmless. It must still be NAMED (acceptance 2) —
  # silence is the original defect — but naming is not refusing.
  def test_integration_disjoint_base_movement_after_the_run_reports_and_does_not_refuse
    with_desk(base_change: "docs/unrelated.md", at: AFTER_RUN) do |dir, head, base_sha|
      verdict, code = check(dir, head)

      assert_equal 0, code,
                   "a base commit with no interaction started REFUSING — every busy night just got " \
                   "worse\n#{verdict.inspect}"
      assert_match(/#{base_sha[0, 12]}/, all_of(verdict),
                   "the movement must still be NAMED — an unnamed green is the defect this task is about")
      assert_match(/docs\/unrelated\.md/, all_of(verdict),
                   "…including WHAT moved, so the disjointness argument can be made from the verdict " \
                   "instead of by hand")
    end
  end

  # THE CONTROL — and the proof the clock is actually read. Identical to the refusal
  # case in every way EXCEPT the base commit's timestamp: same guard file, same
  # overlap, same disjointness. The run finished AFTER it landed, so the green DID
  # cover this tree and there is nothing to refuse.
  #
  # A gate that refused on guard overlap alone — never comparing the timestamps — would
  # go red here. A gate whose timestamp read silently returned nil would fail closed and
  # also go red here. So this row is what stops the refusal above from being credited to
  # a comparison that never happened.
  def test_integration_a_guard_change_the_run_already_covered_does_not_refuse
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: BEFORE_RUN) do |dir, head|
      verdict, code = check(dir, head)

      assert_equal 0, code,
                   "a base commit that landed BEFORE the run completed was refused — the run covered " \
                   "it, and refusing here means the clock was never consulted\n#{verdict.inspect}"
      refute_match(/could not have covered/i, errors_of(verdict))
    end
  end

  # A FOREIGN CLOCK IS NOT EVIDENCE. On a multi-repo task the governing CI verdict is the
  # WORST PR's, which may belong to a different repo than the tree measured here. Its
  # completion time says nothing about this repo's base, so the comparison is not made —
  # and an unmade comparison must not refuse.
  #
  # THE SHAPE IS OTHERWISE THE REFUSING ONE: same late guard change, same overlap. Only
  # the number of PRs differs. So this pins that the guard is the PR COUNT and not some
  # incidental difference in the fixture.
  def test_integration_a_multi_repo_task_does_not_refuse_on_a_foreign_clock
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head|
      verdict, code = check(dir, head, multi_repo: true)

      assert_equal 0, code,
                   "the clock belongs to whichever repo's PR governed the CI read — refusing on it " \
                   "would block correct work over a coincidence\n#{verdict.inspect}"
      assert_match(/MORE THAN ONE PR/, all_of(verdict),
                   "the unmade comparison must name WHY it went unmade, not merely go quiet")
      assert_match(/not a freshness certificate/i, all_of(verdict))
    end
  end

  # BUILDER-SIDE IS UNTOUCHED. At submit the base legitimately moves under a branch all
  # the time and the builder is not the one merging. This guard is about the REVIEW
  # verdict, which is.
  def test_integration_the_builder_gate_does_not_refuse_a_moved_base
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head|
      verdict, code = check(dir, head, review: false)

      assert_equal 0, code, verdict.inspect
      refute_match(/could not have covered/i, errors_of(verdict))
    end
  end

  # NO CLOCK, NO REFUSAL — but no false comfort either. When the run's completion time
  # is unreadable (an injected status, a gh payload without the field) the comparison
  # could not be made. The gate must not invent a refusal from a fact it does not have,
  # and must not let that silence read as "the base movement is fine".
  def test_integration_an_unreadable_ci_clock_reports_the_unmade_check
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head|
      verdict, code = check(dir, head, ci_completed_at: "")

      assert_equal 0, code, verdict.inspect
      assert_match(/could not/i, all_of(verdict),
                   "an unmade check must SAY it went unmade rather than passing silently")
    end
  end
end
