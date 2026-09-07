# frozen_string_literal: true

# [unit] THE CLASSIFIER behind the stale-green refusal
# (/tasks/gate-credits-a-stale-green).
#   ruby -Itest test/lib/base_movement_audit_test.rb
#
# test/lib/dor_check_base_movement_test.rb proves bin/dor-check ASKS this and acts on the
# answer. This file proves the answer is right — the same split as review_tree_guard_test
# (classifier) vs dor_check_zap_seams_test (gate).
#
# THE SUBJECT IS A DISTINCTION, not a lookup. Two questions look alike and are not:
#
#   FILE DISJOINTNESS  base files ∩ PR files.        Somebody else's check. Cheap, and
#                                                    usually right.
#   SHARED GUARD       base files ∩ the tests that   This module. The one shape
#                      GRADE the PR's files,         disjointness is TRUE and IRRELEVANT
#                      minus the PR's own files.     in.
#
# Most of what follows exists to pin them apart, because a version of this module that
# collapsed them would still pass a naive "does it find the guard?" test.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/base_movement_audit"
require_relative "../../bin/lib/fast_cert"

class BaseMovementAuditTest < Minitest::Test
  CI_DONE    = "2026-09-07T07:55:44Z"
  AFTER_RUN  = "2026-09-07T07:59:02Z"
  BEFORE_RUN = "2026-09-07T07:50:00Z"

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

  # A repo carrying a TOOL and its harness test FAMILY — the bin/dor-check →
  # test/lib/dor_check_exempt_ci_test.rb shape that was measured. The PR changes the tool
  # only; the base later changes `base_change`.
  #
  # `merge:` advances `accepted` with a real MERGE COMMIT instead of a fast-forward,
  # which is how `accepted` actually moves ("Merge pull request #NNNN").
  def with_repo(base_change:, at:, merge: false, side_at: nil, extra: {})
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      git!(dir, "init", "-q")
      git!(dir, "config", "user.email", "t@t.co")
      git!(dir, "config", "user.name", "T")

      write(dir, "bin/widget-tool", "# tool\n")
      write(dir, "test/lib/widget_tool_test.rb", "# twin\n")
      write(dir, "test/lib/widget_tool_exempt_test.rb", "# FAMILY guard\n")
      write(dir, "test/lib/other_thing_test.rb", "# unrelated, but mentions widget-tool\n")
      write(dir, "docs/unrelated.md", "prose\n")
      extra.each { |rel, body| write(dir, rel, body) }
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "init", at: BEFORE_RUN)
      git!(dir, "branch", "-M", "accepted")
      git!(dir, "update-ref", "refs/remotes/origin/accepted", "accepted")

      git!(dir, "checkout", "-q", "-b", "feat/x")
      write(dir, "bin/widget-tool", "# tool, edited\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "feat", at: BEFORE_RUN)
      git!(dir, "update-ref", "refs/remotes/origin/feat/x", "feat/x")

      git!(dir, "checkout", "-q", "accepted")
      if merge
        git!(dir, "checkout", "-q", "-b", "other")
        write(dir, base_change, "# moved\n")
        git!(dir, "add", "-A")
        git!(dir, "commit", "-qm", "other PR work", at: side_at || at)
        git!(dir, "checkout", "-q", "accepted")
        git!(dir, "merge", "--no-ff", "-q", "-m", "Merge pull request #1258 from other", "other", at: at)
      else
        write(dir, base_change, "# moved\n")
        git!(dir, "add", "-A")
        git!(dir, "commit", "-qm", "another PR merges", at: at)
      end
      git!(dir, "update-ref", "refs/remotes/origin/accepted", "accepted")
      git!(dir, "checkout", "-q", "feat/x")

      yield dir
    end
  end

  def audit(dir, changed: ["bin/widget-tool"], clock: CI_DONE)
    BaseMovementAudit.assess(root: dir, branch: "feat/x", base: "accepted",
                             changed_files: changed, ci_completed_at: clock)
  end

  # ==== THE SHARED-GUARD SHAPE — what disjointness cannot see ====================

  # The measured incident: the base gained a change to the PR's FAMILY GUARD after the
  # run finished, while touching NONE of the PR's own files.
  def test_a_late_family_guard_is_a_shared_guard
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir|
      a = audit(dir)

      assert_equal :moved, a[:state]
      assert_equal :read, a[:clock]
      assert_equal 1, a[:late].size, "the commit landed after the run and must be counted late"
      assert_equal [{ test: "test/lib/widget_tool_exempt_test.rb", guarding: ["bin/widget-tool"] }],
                   a[:guards]
      # The disjointness argument is TRUE here — and that is exactly the point.
      assert_empty(a[:files] & ["bin/widget-tool"],
                   "fixture: the base must touch none of the PR's files, or this tests the easy case")
    end
  end

  # The convention TWIN counts too, not only the family siblings.
  def test_a_late_convention_twin_is_a_shared_guard
    with_repo(base_change: "test/lib/widget_tool_test.rb", at: AFTER_RUN) do |dir|
      assert_equal ["test/lib/widget_tool_test.rb"], audit(dir)[:guards].map { |g| g[:test] }
    end
  end

  # ==== THE DISTINCTION — shared SOURCE is not shared GUARD =====================

  # When the PR ALSO changes the file the base changed, disjointness FAILS on its own
  # and the overlap machinery already reports it. Claiming it here would collapse the
  # two claims this module exists to keep apart — and would make the refusal fire on a
  # case reviewers already catch, teaching them the refusal is noise.
  def test_a_file_the_pr_also_changes_is_shared_source_not_a_shared_guard
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir|
      a = audit(dir, changed: ["bin/widget-tool", "test/lib/widget_tool_exempt_test.rb"])

      assert_equal :moved, a[:state]
      assert_empty a[:guards],
                   "a file the PR changes itself is the shared-SOURCE shape — disjointness already " \
                   "fails there, and this module must not double-report it as a shared GUARD"
    end
  end

  # A test file that is nobody's guard for this PR must not be claimed, or the refusal
  # fires on ordinary movement and the busy night gets worse.
  def test_an_unrelated_test_file_is_not_a_shared_guard
    with_repo(base_change: "test/lib/other_thing_test.rb", at: AFTER_RUN) do |dir|
      assert_empty audit(dir)[:guards]
    end
  end

  def test_a_non_test_file_is_not_a_shared_guard
    with_repo(base_change: "docs/unrelated.md", at: AFTER_RUN) do |dir|
      a = audit(dir)

      assert_equal :moved, a[:state]
      assert_equal ["docs/unrelated.md"], a[:late_files]
      assert_empty a[:guards]
    end
  end

  # THE NARROWING IS DELIBERATE AND IS PINNED. FastCert maps a source to tests three
  # ways — convention twin, harness family, and a GREP over token identity. This module
  # uses the first two and DROPS the grep rung, because a token search widens to whatever
  # mentions the subject and that width is wrong for something allowed to REFUSE.
  #
  # REACHING THE GREP RUNG TAKES A SOURCE WITH NO TWIN. FastCert only falls back to grep
  # when the convention candidates do not exist on disk, so a fixture whose twin exists
  # exercises the identical code path in both versions and pins nothing. (That is exactly
  # how the first version of this test passed while `guards_for` was widened to
  # FastCert.mapping — an equivalent mutant, not a surviving one.) bin/lib/orphan_thing.rb
  # has no test/lib/orphan_thing_test.rb, so the rung is genuinely reached.
  #
  # THE CONTROL IS THE POINT: FastCert MUST claim the mentioning file here, or this test
  # is asserting the absence of something that was never on offer.
  def test_the_grep_rung_is_not_used_so_a_mere_mention_is_not_a_guard
    orphan = "bin/lib/orphan_thing.rb"
    extra = { orphan => "module OrphanThing; end\n",
              "test/lib/mentions_orphan_test.rb" => "# exercises OrphanThing via #{orphan}\nOrphanThing\n" }

    with_repo(base_change: "test/lib/mentions_orphan_test.rb", at: AFTER_RUN, extra: extra) do |dir|
      assert_empty FastCert.convention_candidates(orphan).select { |t| File.file?(File.join(dir, t)) },
                   "fixture: the orphan must have NO existing twin, or FastCert never reaches its grep rung"
      assert_equal ["test/lib/mentions_orphan_test.rb"], FastCert.mapping(dir, [orphan])[orphan],
                   "control: FastCert's grep rung DOES claim this file — so the assertion below is " \
                   "about a narrowing that is really happening, not about an empty offer"

      assert_empty audit(dir, changed: [orphan])[:guards],
                   "a mere mention is not a guard: widening guards_for to FastCert.mapping would make " \
                   "the gate refuse on evidence a reviewer cannot check in one `ls`"
    end
  end

  # ==== THE CLOCK ================================================================

  # Same guard, same overlap — the run simply finished after it landed, so the green DID
  # cover this tree. Nothing to refuse.
  def test_a_guard_change_before_the_run_completed_is_not_late
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: BEFORE_RUN) do |dir|
      a = audit(dir)

      assert_equal :moved, a[:state]
      assert_empty a[:late], "a commit that predates the run's completion was covered by it"
      assert_empty a[:late_files]
      assert_empty a[:guards], "…and with nothing late there is nothing for the guard hop to find"
    end
  end

  # NO CLOCK IS NOT A CLEAN BILL. An absent completion stamp means the comparison could
  # not be made; it must yield no findings AND must be visible as :unreadable, never
  # silently folded into "nothing late".
  def test_an_unreadable_clock_yields_no_findings_and_says_so
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir|
      a = audit(dir, clock: "")

      assert_equal :moved, a[:state]
      assert_equal :unreadable, a[:clock]
      assert_empty a[:late]
      assert_empty a[:guards]
    end
  end

  # An unparseable stamp must be nil — never epoch, which would make EVERY commit look
  # late and manufacture a refusal out of a read that failed.
  def test_an_unparseable_clock_is_no_clock_not_the_epoch
    assert_nil BaseMovementAudit.parse_time("not a date")
    assert_nil BaseMovementAudit.parse_time(nil)
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir|
      a = audit(dir, clock: "not a date")

      assert_equal :unreadable, a[:clock]
      assert_empty a[:guards]
    end
  end

  # ==== THE MERGE-COMMIT TRAP ====================================================

  # THE REAL-WORLD SHAPE, and the row that caught a defect in this very module.
  #
  # `accepted` advances by MERGE COMMITS, and a merge's side-branch work is invariably
  # OLDER than the merge that lands it. Here the guard change was WRITTEN at 07:30 and
  # LANDED at 07:59:02, while CI finished 07:55:44 — the measured incident's clock, and
  # PR #1258 was itself a merge commit, so this is the ordinary case.
  #
  # WHAT WENT WRONG BEFORE THE FIX: walking every commit in the range read the 07:30
  # committer date, called that work "covered", made it the covered_tip, and computed
  # late_files as diff(07:30-commit .. merge) — EMPTY, because the guard change came
  # FROM that commit. No guards, no refusal: the gate missed the case it exists for.
  #
  # SO THE COMMITTER DATE IS NOT THE LANDING DATE, and only the FIRST-PARENT chain
  # carries the order things joined the base. Revert commits_between to a whole-range
  # walk and this goes red. The earlier version of this test used ONE timestamp for both
  # the side commit and the merge, which made the two walks agree and let the defect
  # through — the gap was in the fixture, not in the idea.
  def test_a_merge_landing_late_is_late_even_when_its_work_is_old
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb",
              side_at: "2026-09-07T07:30:00Z", at: AFTER_RUN, merge: true) do |dir|
      a = audit(dir)

      assert_equal :moved, a[:state]
      assert_equal ["Merge pull request #1258 from other"], a[:late].map { |c| c[:subject] },
                   "the MERGE is what landed after the run; the older work it carries is not a " \
                   "separate landing and must not be read as one"
      assert_includes a[:late_files], "test/lib/widget_tool_exempt_test.rb",
                      "a merge's files must arrive through the two-point diff, or the real `accepted` " \
                      "shape reads as empty"
      assert_equal ["test/lib/widget_tool_exempt_test.rb"], a[:guards].map { |g| g[:test] }
    end
  end

  # The same merge, landing BEFORE the run finished, is covered — so the first-parent
  # walk is not simply "merges are always late". Without this row the test above could
  # be satisfied by a module that never consults the clock at all.
  def test_a_merge_that_landed_before_the_run_is_covered
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb",
              side_at: "2026-09-07T07:30:00Z", at: BEFORE_RUN, merge: true) do |dir|
      a = audit(dir)

      assert_equal :moved, a[:state]
      assert_empty a[:late]
      assert_empty a[:guards]
    end
  end

  # ==== THE QUIET STATES =========================================================

  def test_no_movement_when_the_branch_has_the_base_tip
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      git!(dir, "init", "-q")
      git!(dir, "config", "user.email", "t@t.co")
      git!(dir, "config", "user.name", "T")
      write(dir, "bin/widget-tool", "# tool\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "init")
      git!(dir, "branch", "-M", "accepted")
      git!(dir, "update-ref", "refs/remotes/origin/accepted", "accepted")
      git!(dir, "checkout", "-q", "-b", "feat/x")
      git!(dir, "update-ref", "refs/remotes/origin/feat/x", "feat/x")

      assert_equal :no_movement, audit(dir)[:state]
    end
  end

  # A missing ref is an UNASKED question, never a pass — the caller must be able to tell
  # "I looked and found nothing" from "I could not look".
  def test_a_missing_ref_is_unobservable
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      git!(dir, "init", "-q")

      assert_equal :unobservable, BaseMovementAudit.assess(
        root: dir, branch: "feat/x", base: "accepted",
        changed_files: ["bin/widget-tool"], ci_completed_at: CI_DONE
      )[:state]
    end
  end

  # An empty PR diff can produce no guard overlap — there is nothing to be guarded.
  def test_no_changed_files_means_no_guards
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir|
      assert_empty audit(dir, changed: [])[:guards]
    end
  end
end
