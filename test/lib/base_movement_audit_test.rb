# frozen_string_literal: true

# [unit] THE CLASSIFIER behind the stale-green refusal. test/lib/dor_check_base_movement_test.rb
# proves bin/dor-check ASKS this and acts on the answer; this file proves the answer is right.
# Two questions look alike and are not, and a module collapsing them still passes a naive test:
#   FILE DISJOINTNESS  base files ∩ PR files. Somebody else's check.
#   SHARED GUARD       base files ∩ the tests that GRADE the PR's files, minus the PR's own.
#                      This module: the one shape where disjointness is TRUE and IRRELEVANT.
# History: task gate-credits-a-stale-green.

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/base_movement_audit"
require_relative "../../bin/lib/fast_cert"

class BaseMovementAuditTest < Minitest::Test
  CI_DONE    = "2026-09-07T07:55:44Z"
  AFTER_RUN  = "2026-09-07T07:59:02Z"
  BEFORE_RUN = "2026-09-07T07:50:00Z"
  MID_RUN    = "2026-09-07T07:52:00Z" # after the merge ref was built, before the run ended

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

  def audit(dir, changed: ["bin/widget-tool"], clock: CI_DONE, tested_base: nil)
    BaseMovementAudit.assess(root: dir, branch: "feat/x", base: "accepted",
                             changed_files: changed, ci_completed_at: clock, tested_base: tested_base)
  end

  # RAISES on a ref that does not resolve. `git rev-parse <missing-ref>` prints the REF NAME to
  # stdout and exits 128, so `IO.popen(...).to_s.strip` would hand the literal string on to
  # `audit(tested_base:)`. THAT IS SELF-CERTIFYING: BaseMovementAudit.assess ECHOES the value back
  # (bin/lib/base_movement_audit.rb#assess), so `assert_equal tested, a[:tested_base]` compares
  # the bad string against itself and passes. This helper may not be able to answer with a ref
  # name.
  # History: task sweep-remaining-status-drops.
  def rev(dir, ref)
    out, err, status = Open3.capture3("git", "-C", dir, "rev-parse", ref)
    raise "git rev-parse #{ref.inspect} failed in #{dir} (exit #{status.exitstatus}): #{err.strip}" unless status.success?

    out.strip
  end

  # [control] THE HELPER ABOVE, DRIVEN FROM THE OTHER SIDE: the only test here that tells the
  # repair from the defect, since every other `rev` call passes a ref that resolves. BOTH HALVES
  # ARE MEASURED: that git prints the ref name on stdout with a failing status (the premise), and
  # that the helper refuses to pass it on (the repair). Without the premise the probe could fail
  # some other way.
  # History: task sweep-remaining-status-drops.
  def test_rev_raises_on_a_ref_that_does_not_resolve_rather_than_echoing_its_name
    with_repo(base_change: "docs/unrelated.md", at: AFTER_RUN) do |dir|
      raw, _err, status = Open3.capture3("git", "-C", dir, "rev-parse", "refs/heads/no-such-ref")
      refute status.success?, "premise: a missing ref must exit non-zero"
      assert_equal "refs/heads/no-such-ref", raw.strip,
                   "premise: git echoes the ref NAME on stdout — that string is what a dropped " \
                   "status hands on to audit(tested_base:), where assess echoes it back and " \
                   "assert_equal compares it with itself"

      error = assert_raises(RuntimeError) { rev(dir, "refs/heads/no-such-ref") }
      assert_includes error.message, "no-such-ref", "the failure must name the ref that did not resolve"
      assert_includes error.message, dir, "and the directory it asked in"
      assert_includes error.message, "128", "and the exit status, so a reader can tell it apart from a crash"

      # The other half: a ref that DOES resolve still comes back as a bare SHA, so the
      # repair did not simply turn the helper into something that always raises.
      assert_match(/\A[0-9a-f]{40}\z/, rev(dir, "accepted"))
    end
  end

  # ==== THE MID-RUN WINDOW (/tasks/stale-merge-ref-passes-freshness) =============

  # [unit] base commit between ref build and CI finish. The completion clock calls it
  # covered; ancestry against the base the tested merge ref was built on does not.
  def test_a_mid_run_commit_outside_the_tested_base_is_late
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: MID_RUN) do |dir|
      completion_only = audit(dir)
      assert_empty completion_only[:late], "precondition: the completion clock calls a 07:52 commit covered"
      assert_equal :unchecked, completion_only[:window], "…and must say the window went unchecked"

      tested = rev(dir, "accepted^") # the merge ref was built BEFORE the commit landed
      a = audit(dir, tested_base: tested)
      assert_equal :merge_ref, a[:clock]
      assert_equal :exact, a[:window]
      assert_equal tested, a[:tested_base]
      assert_equal 1, a[:late].size, "the commit is not in the tree CI tested — it is late"
      refute_empty a[:guards], "…and it changes this PR's family guard, the refusable shape"
    end
  end

  # The control: the tested base ALREADY HELD the commit, so ancestry calls it covered.
  def test_a_commit_inside_the_tested_base_is_covered_whatever_the_clock
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir|
      a = audit(dir, tested_base: rev(dir, "accepted"))
      assert_equal :merge_ref, a[:clock]
      assert_empty a[:late], "ancestry says covered; a clock that disagrees must not win"
    end
  end

  # A merge commit lands side-branch work OLDER than the merge. Ancestry follows the
  # landing, not the committer date — the reason this is ancestry and not a better clock.
  def test_ancestry_counts_a_merged_side_branch_by_when_it_landed
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: MID_RUN, merge: true,
              side_at: BEFORE_RUN) do |dir|
      a = audit(dir, tested_base: rev(dir, "accepted^1"))
      assert_equal 1, a[:late].size, "the merge landed after the ref was built, whatever its side's dates"
      assert_includes a[:late_files], "test/lib/widget_tool_exempt_test.rb"
    end
  end

  # ── D1: THE RELEASE BACK-MERGE (/tasks/freshness-verdict-states-falsehoods) ─────
  #
  # accepted on 2026-09-10: tip 50cfea07 = merge(beb44fb9, 377f0424), the tested base the
  # SECOND parent. Every first-parent commit is then a non-ancestor, and a late_files diff
  # taken from fork_point sweeps in what the tested base ITSELF contributed.
  def with_back_merge(release_change:)
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      git!(dir, "init", "-q")
      git!(dir, "config", "user.email", "t@t.co")
      git!(dir, "config", "user.name", "T")
      write(dir, "bin/widget-tool", "# tool\n")
      write(dir, "test/lib/widget_tool_test.rb", "# twin\n")
      write(dir, "test/lib/widget_tool_exempt_test.rb", "# FAMILY guard\n")
      write(dir, "docs/unrelated.md", "prose\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "init", at: BEFORE_RUN)
      git!(dir, "branch", "-M", "accepted")
      init = rev(dir, "accepted")

      git!(dir, "checkout", "-q", "-b", "feat/x")
      write(dir, "bin/widget-tool", "# tool, edited\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "feat", at: BEFORE_RUN)
      git!(dir, "update-ref", "refs/remotes/origin/feat/x", "feat/x")

      # accepted gains the GUARD change — and the PR's merge ref is built on THAT.
      git!(dir, "checkout", "-q", "accepted")
      write(dir, "test/lib/widget_tool_exempt_test.rb", "# guard, changed before the ref was built\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "guard change", at: BEFORE_RUN)
      tested = rev(dir, "accepted")

      # A release-side branch, then the back-merge: release FIRST parent, accepted SECOND.
      git!(dir, "checkout", "-q", "-b", "release-side", init)
      if release_change
        write(dir, "docs/unrelated.md", "release prose\n")
        git!(dir, "add", "-A")
        git!(dir, "commit", "-qm", "release work", at: AFTER_RUN)
      else
        git!(dir, "commit", "-q", "--allow-empty", "-m", "release work, no content", at: AFTER_RUN)
      end
      git!(dir, "merge", "--no-ff", "-q", "-m", "Merge remote-tracking branch 'origin/main' into HEAD",
           "accepted", at: AFTER_RUN)
      git!(dir, "update-ref", "refs/remotes/origin/accepted", "release-side")
      git!(dir, "checkout", "-q", "feat/x")

      yield dir, tested
    end
  end

  # [unit] criss-cross base: late_files excludes tested-base content.
  def test_a_back_merged_tip_diffs_late_files_from_the_tested_base
    with_back_merge(release_change: true) do |dir, tested|
      a = audit(dir, tested_base: tested)

      assert_equal :merge_ref, a[:clock]
      assert_equal ["docs/unrelated.md"], a[:late_files],
                   "late_files swept in what the TESTED BASE itself contributed"
      assert_empty a[:guards],
                   "the tested base already held the guard change — refusing on it is a FALSE refusal"
    end
  end

  # The live ms#1370 shape: the back-merge changes no file relative to the tested base.
  # Non-ancestor commits, identical trees — the green saw everything that ships.
  def test_a_back_merge_identical_to_the_tested_tree_is_covered
    with_back_merge(release_change: false) do |dir, tested|
      a = audit(dir, tested_base: tested)

      assert_empty a[:late_files]
      assert_empty a[:late], "identical trees are covered; a late list with no late files renders a falsehood"
    end
  end

  # A tested base this checkout does not hold cannot be asked — say so, keep the clock.
  def test_an_unknown_tested_base_leaves_the_window_unchecked
    with_repo(base_change: "test/lib/widget_tool_exempt_test.rb", at: AFTER_RUN) do |dir|
      a = audit(dir, tested_base: "0" * 40)
      assert_equal :read, a[:clock], "falls back to the completion LOWER bound"
      assert_equal :unchecked, a[:window]
      assert_equal :not_local, a[:window_reason]
      assert_equal 1, a[:late].size, "the lower bound still flags what provably landed after the run"
    end
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

  # THE NARROWING IS DELIBERATE AND IS PINNED. FastCert maps a source three ways: convention twin,
  # harness family, and a GREP over token identity. This module DROPS the grep rung: a token
  # search widens to whatever mentions the subject, wrong for something allowed to REFUSE.
  # REACHING THE GREP RUNG TAKES A SOURCE WITH NO TWIN: a fixture whose twin exists pins nothing.
  # bin/lib/orphan_thing.rb has no test/lib/orphan_thing_test.rb, so the rung is reached. THE
  # CONTROL IS THE POINT: FastCert MUST claim the mentioning file here, or this asserts the
  # absence of something never on offer.
  # History: task gate-credits-a-stale-green.
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

  # ==== THE LATE WINDOW HAS A LOWER EDGE ========================================

  # The base gained TWO landings: the guard change BEFORE the run finished, and an
  # unrelated change after. The run covered the guard change, so there is nothing to
  # refuse — only the movement after the cutoff is uncovered.
  #
  # This is what stops the late window from being "all movement since the fork". Widen
  # covered_tip to the fork point and this goes red, because the guard would be dragged
  # into a window the run demonstrably did cover.
  def test_only_movement_after_the_cutoff_counts_as_late
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      git!(dir, "init", "-q")
      git!(dir, "config", "user.email", "t@t.co")
      git!(dir, "config", "user.name", "T")
      write(dir, "bin/widget-tool", "# tool\n")
      write(dir, "test/lib/widget_tool_test.rb", "# twin\n")
      write(dir, "test/lib/widget_tool_exempt_test.rb", "# FAMILY guard\n")
      write(dir, "docs/unrelated.md", "prose\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "init", at: "2026-09-07T07:00:00Z")
      git!(dir, "branch", "-M", "accepted")
      git!(dir, "update-ref", "refs/remotes/origin/accepted", "accepted")

      git!(dir, "checkout", "-q", "-b", "feat/x")
      write(dir, "bin/widget-tool", "# tool, edited\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "feat", at: "2026-09-07T07:10:00Z")
      git!(dir, "update-ref", "refs/remotes/origin/feat/x", "feat/x")

      git!(dir, "checkout", "-q", "accepted")
      write(dir, "test/lib/widget_tool_exempt_test.rb", "# guard change the run DID see\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "guard change, covered", at: BEFORE_RUN)
      write(dir, "docs/unrelated.md", "prose, later\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "unrelated, after the run", at: AFTER_RUN)
      git!(dir, "update-ref", "refs/remotes/origin/accepted", "accepted")
      git!(dir, "checkout", "-q", "feat/x")

      a = audit(dir)

      assert_equal 2, a[:commits].size
      assert_equal ["unrelated, after the run"], a[:late].map { |c| c[:subject] }
      assert_equal ["docs/unrelated.md"], a[:late_files],
                   "the late window starts at the newest landing the run could have seen — not at the fork"
      assert_empty a[:guards],
                   "the guard change landed BEFORE the run finished, so the green covered it and there " \
                   "is nothing here to refuse"
    end
  end

  # ==== THE MERGE-COMMIT TRAP ====================================================

  # THE REAL-WORLD SHAPE. `accepted` advances by MERGE COMMITS, and a merge's side-branch work is
  # OLDER than the merge. Walking every commit reads the old committer date, calls that work
  # "covered", and computes late_files as an EMPTY diff: no guards, no refusal. THE COMMITTER DATE
  # IS NOT THE LANDING DATE; only the FIRST-PARENT chain carries the order things joined the base.
  # Revert commits_between to a whole-range walk and this goes red. Side commit and merge need
  # different timestamps, or the two walks agree and the fixture hides the defect.
  # History: task gate-credits-a-stale-green.
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

  # THE REASON IS PART OF THE ANSWER. bin/dor-check renders a DIFFERENT REMEDY per reason (fetch
  # the ref / unshallow the clone / git itself is unreadable). Collapse the four into one
  # :unobservable and the gate says "could not run" with a remedy that does not apply. TWO OF THE
  # FOUR ARE FIXTURABLE. :no_log and :git_unreadable would need stubbing the process table, and a
  # stub shaped from this module's code would certify that code. They are left to the caller's
  # default arm, which names the raw reason either way.
  # History: task audit-vanishes-when-git-fails.
  def test_the_unobservable_reasons_are_distinguishable
    Dir.mktmpdir do |raw|
      dir = File.realpath(raw)
      git!(dir, "init", "-q")

      result = BaseMovementAudit.assess(
        root: dir, branch: "feat/x", base: "accepted",
        changed_files: ["bin/widget-tool"], ci_completed_at: CI_DONE
      )
      assert_equal :unobservable, result[:state]
      assert_equal :no_ref, result[:reason],
                   "a ref this checkout simply does not have is :no_ref, and its remedy is a fetch — " \
                   "the ONE remedy that applies, since this gate never fetches for itself"
    end

    # BOTH REFS RESOLVE, and there is still no common ancestor: two roots that never met.
    # A different failure from a missing ref, and a different remedy — so it must not
    # arrive under the same name.
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

      git!(dir, "checkout", "-q", "--orphan", "feat/x")
      write(dir, "bin/widget-tool", "# a history that never met accepted\n")
      git!(dir, "add", "-A")
      git!(dir, "commit", "-qm", "orphan root")
      git!(dir, "update-ref", "refs/remotes/origin/feat/x", "feat/x")

      result = audit(dir)
      assert_equal :unobservable, result[:state],
                   "refs that resolve are not an answer — the QUESTION is about their common ancestor"
      assert_equal :no_merge_base, result[:reason],
                   "resolvable-but-unrelated is NOT the missing-ref failure, and telling the reviewer " \
                   "to fetch would send them after a ref they already have"
    end
  end
end
