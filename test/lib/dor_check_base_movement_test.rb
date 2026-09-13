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
# on pull_request and on pushes to main, release AND `accepted` — so a merge into
# `accepted` DOES start a run. That run grades the `accepted` TIP, a tree this PR is not
# in, and nothing re-runs THIS PR against the moved base, so the combination that ships
# is never executed. If `accepted` advances after the run, THE GREEN NEVER COVERED THE
# MERGE, and `--gate-role review` credited it anyway.
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
  # AFTER GitHub built this PR's merge ref, BEFORE the run finished. The completion clock
  # calls this "covered"; the tree CI tested never held it (tm#682: merge ref 06:19Z,
  # tm#677 landed 06:26Z and tm#678 06:40Z, run still going — both waved through).
  MID_RUN     = "2026-09-07T07:52:00Z"

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

  def check(root, desk_head, ci_completed_at: CI_DONE, review: true, multi_repo: false, tested_base: nil)
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
        "DOR_CHECK_CI_TESTED_BASE" => tested_base,
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

      # THE DURABLE ROW, not just the exit code. `ci_gate_result` is what the gates
      # card renders and what the GateRun sop records, and it is the half a reader
      # meets LATER — after the terminal output that carried the refusal is gone.
      #
      # It said "pass" here until 2026-09-07. The refusal set `ci_review_refused =
      # true`, but CiGate.gate_row read that flag only in its `else` branch, and this
      # path's precondition IS `ci[:state] == :green` — so the assignment was inert and
      # the board recorded a passing CI row for a review the same run had refused. That
      # is precisely this task's defect (a green credited for a tree nobody ran) leaking
      # into the record, and deleting the assignment left all six integration tests
      # green because nothing ever asserted on this field.
      assert_equal "fail", verdict["ci_gate_result"],
                   "the gates-card CI row recorded PASS on a run that REFUSED the review — the durable " \
                   "record contradicts the verdict that produced it\nverdict: #{verdict.inspect}"

      # THE TWO HALVES MUST NOT CONTRADICT EACH OTHER. The movement REPORT and the
      # REFUSAL both fire on this run — same refs, same movement — and the report used to
      # append "None of those is a test that grades a file this PR changes" unconditionally.
      # That is the exact negative the refusal has just disproved, about the exact same
      # file, in one verdict; and it is not a harmless duplication, because the false half
      # hands the reader the disjointness argument the refusal exists to refute.
      refute_match(/None of those is a test that grades/, all_of(verdict),
                   "the report half asserted a negative the refusal half disproved — one verdict named the " \
                   "same file as both a guard and not-a-guard\n#{all_of(verdict)}")

      # ON THE SUGGESTIONS LANE SPECIFICALLY, and that is the point of these three.
      # The contradiction lived in the REPORT, which lands in `suggestions`; the refusal
      # lands in `errors`. Asserting the repair over all_of (errors + suggestions joined)
      # cannot tell those apart, so it is satisfied by the refusal's own text and says
      # NOTHING about the half that was wrong. Concretely: move the withheld-claim
      # sentence into the refusal and let the report go silent, and an all_of assertion
      # still passes — which is exactly the "simply going quiet" outcome it claims to
      # forbid. The original test asserted only on errors_of and never on suggestions_of,
      # which is why the contradiction shipped green in the first place.
      assert_match(/DISJOINTNESS IS NOT AVAILABLE HERE/, suggestions_of(verdict),
                   "…and having withheld the disjointness claim, the REPORT must say WHY it is withheld " \
                   "rather than simply going quiet\nsuggestions: #{suggestions_of(verdict)}")
      refute_match(/None of those is a test that grades/, suggestions_of(verdict),
                   "the report lane is where the false negative lived — pin it there, not only in the " \
                   "union with the refusal that disproves it\nsuggestions: #{suggestions_of(verdict)}")
      # THE TWO LANES MUST NAME THE SAME FILE, and this pins it INSIDE the withheld-claim
      # sentence rather than anywhere in the lane. A bare
      # `assert_match(/widget_tool_exempt_test/, suggestions_of(...))` proves nothing
      # here: the movement report already prints "FILES: <that file>" unconditionally,
      # several sentences earlier, so it passes even when the disjointness block is
      # deleted outright. Measured — with that block emptied, this row still failed on
      # ONE assertion (the "going quiet" one above) and a bare name-match did not
      # contribute. Anchoring to the sentence is what makes it a real agreement check.
      assert_match(/DISJOINTNESS IS NOT AVAILABLE HERE:[^.]*widget_tool_exempt_test\.rb/,
                   suggestions_of(verdict),
                   "the report must name the guard INSIDE the sentence that withholds the claim — the " \
                   "refusal and the report have to be about the same file, or they are two verdicts " \
                   "rather than two halves of one\nsuggestions: #{suggestions_of(verdict)}")
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

      # THE OTHER HALF of the guards conditional. The refusing row pins that the
      # disjointness claim is WITHHELD when a guard moved; without this, the branch that
      # still MAKES the claim is unpinned, and collapsing the conditional the other way
      # (always withhold) passes the suite silently — measured during review.
      assert_match(/FILE DISJOINTNESS is available here/, suggestions_of(verdict),
                   "on the shape where disjointness genuinely does settle it, the report must still say " \
                   "so — a conditional has two halves and an unasserted half is an unproved one. " \
                   "SUGGESTIONS lane, for the reason given on the refusing row: there are no errors here " \
                   "at all, so all_of would prove nothing about WHERE the claim was made" \
                   "\nsuggestions: #{suggestions_of(verdict)}")
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
  # ── THE MID-RUN WINDOW (/tasks/stale-merge-ref-passes-freshness) ─────────────────
  #
  # CI tests the merge ref GitHub built when the run was TRIGGERED, and the run then
  # takes many minutes. A base commit landing inside that window predates the run's
  # COMPLETION, so a completion clock calls it covered — while the tree CI tested never
  # held it. The exact question is ancestry, not time: is the commit in the base the
  # merge ref was built from? DOR_CHECK_CI_TESTED_BASE injects that base, as
  # DOR_CHECK_CI_COMPLETED_AT injects the clock.
  def test_integration_a_guard_change_landing_mid_run_is_refused
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: MID_RUN) do |dir, head, base_sha|
      tested = IO.popen(["git", "-C", dir, "rev-parse", "#{base_sha}^"], &:read).to_s.strip
      verdict, code = check(dir, head, tested_base: tested)

      refute_equal 0, code,
                   "the review gate returned READY on a guard change that landed at 07:52 — BEFORE the " \
                   "run completed (07:55:44) but AFTER the merge ref it tested was built on " \
                   "#{tested[0, 12]}. The green never saw it.\n#{verdict.inspect}"
      assert_match(/test\/lib\/widget_tool_exempt_test\.rb/, errors_of(verdict),
                   "the refusal must NAME the guard that moved")
      assert_match(/#{tested[0, 12]}/, errors_of(verdict),
                   "…and the base the tested merge ref was built on, the evidence a reviewer checks")
      # D2, the branch where the clause is TRUE: the commit predates the run's completion,
      # so a completion clock would have called it covered — and the refusal says so, exactly.
      assert_includes errors_of(verdict),
                      "1 of 1 landed before the run completed at 2026-09-07T07:55:44Z, so a completion " \
                      "clock would have called it covered"
    end
  end

  # D2, the branch where the old clause was FALSE (/tasks/freshness-verdict-states-falsehoods).
  # The commit lands AFTER the run completed; a completion clock would have CAUGHT it. The
  # refusal must not claim otherwise — a reader disproves that from two printed timestamps.
  def test_integration_a_post_run_refusal_makes_no_completion_clock_claim
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head, base_sha|
      tested = IO.popen(["git", "-C", dir, "rev-parse", "#{base_sha}^"], &:read).to_s.strip
      verdict, code = check(dir, head, tested_base: tested)

      refute_equal 0, code, "precondition: this is the refusing shape\n#{verdict.inspect}"
      refute_match(/completion clock (would have called|calls) (it|them) covered/, errors_of(verdict),
                   "the commit landed AFTER completion (07:59:02 > 07:55:44); a completion clock catches it")
    end
  end

  # D3 — the disclosure itself is PRINTED, not merely set on the module's hash.
  def test_integration_an_unresolved_tested_base_prints_the_unchecked_window
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head|
      verdict, = check(dir, head, tested_base: "none")

      assert_includes all_of(verdict),
                      "THE MID-RUN WINDOW WENT UNCHECKED: the base this PR's merge ref was built on could not " \
                      "be resolved (the tested base was injected as unresolvable), so a base commit that " \
                      "landed after GitHub built that ref but before the run finished would read as covered here."
    end
  end

  # S1 — GitHub DID resolve the base; only this checkout lacks it. "Could not be resolved" is
  # false there, and the one reason with a remedy must name it.
  def test_integration_a_tested_base_missing_locally_says_fetch_not_unresolved
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head|
      missing = "f" * 40
      verdict, = check(dir, head, tested_base: missing)

      refute_match(/could not be resolved/, all_of(verdict), "GitHub resolved it; the checkout lacks it")
      assert_includes all_of(verdict),
                      "THE MID-RUN WINDOW WENT UNCHECKED: this PR's merge ref was built on #{missing[0, 12]}, " \
                      "which is not in this checkout — run `git fetch origin` and re-check."
    end
  end

  # THE CONTROL. Same commit, same clock, same guard overlap — but the tested merge ref was
  # built on a base that ALREADY HELD it. Refusing here would mean the new path keys on the
  # seam being set rather than on ancestry.
  def test_integration_a_guard_change_inside_the_tested_merge_ref_does_not_refuse
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: MID_RUN) do |dir, head, base_sha|
      verdict, code = check(dir, head, tested_base: base_sha)

      assert_equal 0, code,
                   "the tested merge ref was built on #{base_sha[0, 12]}, which holds the guard change — " \
                   "the run covered it, and refusing means ancestry was never consulted\n#{verdict.inspect}"
      assert_includes all_of(verdict),
                      "Everything it changed is already in the tree this PR's CI tested — its merge ref was " \
                      "built on #{base_sha[0, 12]} — so the run did cover this tree."
    end
  end

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

  # ==== THE AUDIT'S OWN SILENCE (/tasks/audit-vanishes-when-git-fails) ===========
  #
  # Every row above consumes :moved. `assess` also answers :unobservable — from FOUR
  # paths (:no_ref, :no_merge_base, :no_log, :git_unreadable) — and NOTHING outside the
  # module consumed it. Grepped on `accepted` at c92f8d73: the only other :unobservable
  # reads in bin/ are a DIFFERENT audit (head_check/:no_pr_head). So any failed git read
  # made gate-zero's deepest check report nothing at all, and the review proceeded
  # exactly as though the base had not moved.
  #
  # THAT IS THE DEFECT CLASS THIS SEAM EXISTS TO CLOSE, reproduced inside the check
  # itself: a check that silently does not run. It fails toward the status quo, which is
  # the safe direction — and it fails SILENTLY, which is the direction that costs a
  # reviewer the one fact they needed.
  #
  # THE FIXTURE IS THE REAL SHAPE, not an injected state. It strips BOTH refs the audit
  # resolves the base through (the remote-tracking ref AND the local branch its fallback
  # reaches for), which is the :no_ref path — and :no_ref is the one a live desk actually
  # hits, because THIS GATE NEVER FETCHES. Everything else about the desk is the REFUSING
  # row: same late guard change, same overlap. Only the readability of the ref differs.

  def strip_base_refs!(dir)
    git!(dir, "update-ref", "-d", "refs/remotes/origin/accepted")
    git!(dir, "branch", "-D", "accepted")
  end

  def test_integration_an_unobservable_base_audit_names_the_unmade_check
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head|
      strip_base_refs!(dir)

      verdict, = check(dir, head)

      assert_match(/BASE-MOVEMENT AUDIT could not run/i, all_of(verdict),
                   "a git read the audit could not make must SAY so. Silence here is indistinguishable " \
                   "from 'the base did not move' — and telling those two apart IS this seam" \
                   "\n#{all_of(verdict)}")
      assert_match(/no_ref/, all_of(verdict),
                   "the REASON must be named: the four unobservable paths have different remedies " \
                   "(fetch the ref / unshallow / git is unreadable), and a report whose remedy the " \
                   "reader cannot derive is the tip-SHA-and-count report this seam replaced")
      assert_match(/not a freshness certificate/i, all_of(verdict),
                   "…and it must refuse to read as reassurance, for the same reason " \
                   ":no_movement_seen is never rendered as 'the base is current'")
    end
  end

  # THE OTHER HALF, and it is not decoration. Refusing on :unobservable would be a
  # SECOND defect rather than a stricter fix: :no_ref is reachable on any checkout that
  # lacks origin/<base>, and this gate NEVER FETCHES by design — so a refusal would wedge
  # gate-zero on a condition the gate itself creates. Silence was the defect; strictness
  # is its mirror image. Without this row, a fix that refused would pass the row above.
  def test_integration_an_unobservable_base_audit_does_not_refuse
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head|
      strip_base_refs!(dir)

      verdict, code = check(dir, head)

      assert_equal 0, code,
                   "an unreadable ref must not refuse a review — every desk that has not fetched " \
                   "would wedge, and a gate that refuses correct work is one reviewers route around" \
                   "\n#{errors_of(verdict)}"
      refute_match(/could not have covered/i, errors_of(verdict),
                   "the stale-green REFUSAL is a claim about a guard that provably moved; it must " \
                   "never be manufactured out of a read that failed")
    end
  end

  # THE SIGNAL IS NOT PARASITIC ON base_check. ReviewTreeGuard.base_assessment and this
  # audit are two SEPARATE readers over the same refs, and the report is rendered in two
  # different places (base_movement_detail hangs off base_check[:state] == :moved).
  # Hanging the unobservable signal off that branch would keep the audit silent in
  # exactly the case where BOTH reads failed — which is the LIKELIEST case, since they
  # fail for the same reason. This row is what pins them apart: here base_check cannot
  # see movement either, so the base-moved suggestion never fires, and the audit's own
  # report has to stand on its own or there is nothing at all.
  def test_integration_the_unobservable_report_stands_without_the_base_moved_suggestion
    with_desk(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir, head|
      strip_base_refs!(dir)

      verdict, = check(dir, head)

      refute_match(/the base has MOVED since this branch last took it/, all_of(verdict),
                   "fixture check: with both refs stripped base_check is unobservable too, so the " \
                   "base-moved suggestion must NOT be what is carrying the report")
      assert_match(/BASE-MOVEMENT AUDIT could not run/i, all_of(verdict),
                   "…and the audit's own signal must still be there. If this row goes red while the " \
                   "first passes, the signal was wired to base_check and is silent when it matters " \
                   "most\n#{all_of(verdict)}")
    end
  end
end
