# frozen_string_literal: true

# Unit tests for MergePermission: the documentation seat merges a docs-shape diff
# and nothing else, measured from the PR's files at the head being merged.
#
# Every refusal here has a CONTROL beside it: the same inputs with one fact
# changed permit. So a refusal is shown to come from the rule under test and not
# from an input that would refuse anyway, and deleting the rule reddens the test.
#
# Run directly:  ruby -Itest test/lib/merge_permission_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/merge_permission"

class MergePermissionTest < Minitest::Test
  HEAD = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
  LATER = "ffffffffffffffffffffffffffffffffffffffff"

  # One file list per shape the classifier can emit, and more than one where a
  # shape has distinct faces. DIFF_SHAPES is asserted covered below.
  DIFFS = {
    "docs" => [
      %w[docs/agents/modules/focus-session.md],
      %w[docs/agents/modules/focus-session.md test/docs/focus_session_docs_test.rb],
      %w[README.md docs/img/flow.png],
      %w[docs/a.md test/lib/devops_shift_argument_guard_test.rb]
    ],
    "test-only" => [
      %w[test/models/task_test.rb],
      %w[test/docs/focus_session_docs_test.rb],
      %w[e2e/board.spec.js test/lib/merge_command_test.rb]
    ],
    "code" => [
      %w[app/models/task.rb],
      %w[bin/submit],
      %w[Gemfile.lock],
      %w[.github/workflows/ci.yml],
      %w[app/models/task.rb test/models/task_test.rb],
      %w[docs/agents/setup.sh]
    ],
    "mixed" => [
      %w[docs/agents/modules/focus-session.md app/models/task.rb],
      %w[README.md test/models/task_test.rb],
      %w[docs/a.md test/docs/helper.rb],
      %w[docs/deploy-notes.md bin/deploy.sh]
    ],
    "unread" => [[], [""], nil]
  }.freeze

  def decide(**overrides)
    MergePermission.decide(**{
      soul: "xan", files: DIFFS.fetch("docs").first, authors: %w[pokemon],
      verdict: { "outcome" => "merge-ready", "reporter" => "xan", "head" => HEAD },
      head: HEAD, live_head: HEAD
    }.merge(overrides))
  end

  # ── the classifier ────────────────────────────────────────────────────────

  def test_every_shape_the_classifier_emits_has_a_fixture
    assert_equal MergePermission::DIFF_SHAPES.sort, DIFFS.keys.sort,
                 "a shape diff_shape can return has no fixture here, so its refusal is untested"
  end

  def test_diff_shape_names_each_fixture
    DIFFS.each do |shape, lists|
      lists.each do |files|
        assert_equal shape, MergePermission.diff_shape(files), "diff_shape(#{files.inspect})"
      end
    end
  end

  # The measure is CodeDiff's and TestOnlyDiff's, not a second copy of their rules.
  def test_docs_is_exactly_the_gates_docs_predicate
    DIFFS.values.flatten(1).each do |files|
      assert_equal CodeDiff.docs_with_guards?(files), MergePermission.diff_shape(files) == "docs",
                   "diff_shape disagrees with CodeDiff.docs_with_guards? on #{files.inspect}"
    end
  end

  # A rename's source counts: bin/deploy.sh renamed to a .md lists both paths.
  def test_a_renamed_script_is_not_prose
    assert_equal "mixed", MergePermission.diff_shape(%w[docs/deploy-notes.md bin/deploy.sh])
    assert_equal "docs", MergePermission.diff_shape(%w[docs/deploy-notes.md docs/old-notes.md])
  end

  # ── acceptance 1: the seat merges a docs-shape PR after a merge-ready verdict ──

  def test_permits_the_documentation_seat_on_every_docs_diff
    DIFFS.fetch("docs").each do |files|
      result = decide(files: files)

      assert result.permitted?, "xan must merge #{files.inspect}: #{result.reason}"
      assert_equal :docs_seat, result.code
    end
  end

  def test_the_retired_slug_is_the_same_seat
    assert_equal :docs_seat, decide(soul: "alex").code
    assert_equal :shape_code, decide(soul: "alex", files: %w[app/models/task.rb]).code
  end

  # ── acceptance 2: every other shape is refused for the seat ───────────────

  def test_refuses_the_documentation_seat_on_every_other_shape
    (MergePermission::DIFF_SHAPES - %w[docs]).each do |shape|
      DIFFS.fetch(shape).each do |files|
        result = decide(files: files)

        refute result.permitted?, "xan must not merge a #{shape} diff #{files.inspect}"
        assert_equal :"shape_#{shape.tr("-", "_")}", result.code
        assert_match(/documentation seat \(xan\) merges docs-shape PRs only/, result.reason)
        assert_match(/measures #{shape} at a1b2c3d/, result.reason)
        assert_match(/Carl, the standing primary, merges it/, result.reason)
        # CONTROL: the same diff, the same verdict, a soul the rule does not limit.
        assert decide(files: files, soul: "carl").permitted?, "carl's merge of #{files.inspect} must be unchanged"
      end
    end
  end

  def test_the_refusal_names_the_files_that_are_not_prose
    reason = decide(files: %w[docs/a.md app/models/task.rb bin/submit]).reason

    assert_includes reason, "app/models/task.rb, bin/submit"
    refute_includes reason, "docs/a.md,"
  end

  # The card's declared shape is not an input: there is nowhere to pass it.
  def test_the_decision_takes_no_declared_shape
    refute_includes MergePermission.method(:decide).parameters.map(&:last), :shape
  end

  # ── the diff changed shape after the verdict ──────────────────────────────

  def test_refuses_when_the_head_moved_after_the_verdict
    result = decide(live_head: LATER, files: %w[docs/a.md app/models/task.rb])

    refute result.permitted?
    assert_equal :head_moved, result.code
    assert_match(/head is fffffff, not the validated a1b2c3d/, result.reason)
    # CONTROL: a docs diff at the new head is still refused, so it is the moved
    # head that refuses and not the code file.
    assert_equal :head_moved, decide(live_head: LATER).code
    assert decide(live_head: HEAD).permitted?
  end

  def test_refuses_a_code_file_added_under_a_verdict_re_recorded_for_the_new_head
    # The author pushes a code file and the verdict is re-pointed at the new head:
    # the head matches again, and the re-measured diff is what refuses.
    verdict = { "outcome" => "merge-ready", "reporter" => "xan", "head" => LATER }
    result = decide(head: LATER, live_head: LATER, verdict: verdict, files: %w[docs/a.md app/models/task.rb])

    assert_equal :shape_mixed, result.code
    assert decide(head: LATER, live_head: LATER, verdict: verdict).permitted?, "control: prose at that head permits"
  end

  def test_refuses_a_verdict_that_judged_another_head
    result = decide(verdict: { "outcome" => "merge-ready", "reporter" => "xan", "head" => LATER })

    assert_equal :verdict_other_head, result.code
    assert_match(/judged fffffff, not a1b2c3d/, result.reason)
  end

  def test_refuses_a_verdict_that_names_no_head
    result = decide(verdict: { "outcome" => "merge-ready", "reporter" => "xan" })

    assert_equal :verdict_names_no_head, result.code
    assert_match(/--head a1b2c3d/, result.reason)
  end

  def test_refuses_without_a_validated_head
    assert_equal :no_head, decide(head: " ", live_head: "").code
  end

  def test_head_comparison_ignores_case_and_padding
    assert decide(head: " #{HEAD.upcase} ", live_head: HEAD).permitted?
  end

  # ── the verdict must be on the card, from a reviewer allowed to give it ────

  def test_refuses_without_a_merge_ready_verdict
    [nil, {}, { "outcome" => "request-changes", "reporter" => "xan", "head" => HEAD },
     { "outcome" => "wait-for-ci", "reporter" => "carl", "head" => HEAD }].each do |verdict|
      result = decide(verdict: verdict)

      assert_equal :no_verdict, result.code, "verdict #{verdict.inspect}"
      refute result.permitted?
    end
  end

  def test_refuses_a_verdict_from_outside_the_review_pool
    %w[pokemon avi mack avi-scout].each do |reporter|
      result = decide(verdict: { "outcome" => "merge-ready", "reporter" => reporter, "head" => HEAD })

      assert_equal :verdict_not_reviewer, result.code, "reporter #{reporter}"
    end
    assert_equal :verdict_not_reviewer, decide(verdict: { "outcome" => "merge-ready", "head" => HEAD }).code
  end

  def test_accepts_a_verdict_from_each_pool_reviewer
    MergePermission::REVIEWERS.each do |reporter|
      assert decide(verdict: { "outcome" => "merge-ready", "reporter" => reporter, "head" => HEAD }).permitted?,
             "a merge-ready verdict from #{reporter} must authorise the seat's merge"
    end
  end

  def test_refuses_a_verdict_given_by_an_author
    result = decide(authors: %w[pokemon carl],
                    verdict: { "outcome" => "merge-ready", "reporter" => "carl", "head" => HEAD })

    assert_equal :verdict_from_author, result.code
    # CONTROL: the same verdict when its reporter is not an author.
    assert decide(authors: %w[pokemon],
                  verdict: { "outcome" => "merge-ready", "reporter" => "carl", "head" => HEAD }).permitted?
  end

  # The pool is ReviewerSelector's, re-spelled because this file runs without Rails.
  def test_the_reviewer_pool_matches_the_selectors
    source = File.read(File.expand_path("../../app/services/reviewer_selector.rb", __dir__))
    pool = source[/^\s*POOL = %w\[([^\]]+)\]/, 1].to_s.split

    refute_empty pool, "ReviewerSelector::POOL moved; re-point this pin"
    assert_equal pool.sort, MergePermission::REVIEWERS.sort
    assert_includes source, %(STANDING_PRIMARY = "#{MergePermission::STANDING_PRIMARY}")
  end

  # ── no self-review ────────────────────────────────────────────────────────

  def test_refuses_the_seat_on_its_own_pr
    [%w[xan], %w[pokemon xan], %w[alex], [" Xan "]].each do |authors|
      result = decide(authors: authors)

      refute result.permitted?, "authors #{authors.inspect}"
      assert_equal :self_review, result.code
      assert_match(/never merges its own work/, result.reason)
    end
    # CONTROL: the same docs diff and verdict with the seat outside the author set.
    assert decide(authors: %w[pokemon]).permitted?
  end

  def test_refuses_when_the_author_set_is_unknown
    [nil, [], ["", " "]].each do |authors|
      assert_equal :authors_unread, decide(authors: authors).code, "authors #{authors.inspect}"
    end
  end

  def test_names_another_primary_when_carl_is_an_author
    reason = decide(authors: %w[carl], files: %w[app/models/task.rb],
                    verdict: { "outcome" => "merge-ready", "reporter" => "steffon", "head" => HEAD }).reason

    assert_match(/Carl is an author here, so a primary outside the author set merges it/, reason)
  end

  # ── Carl, and every other soul, is unchanged ──────────────────────────────

  def test_the_rule_limits_only_the_documentation_seat
    assert_equal %w[xan], MergePermission::SHAPE_LIMITED.keys

    %w[carl shannon jasper steffon].each do |soul|
      # Nothing the seat is refused for reaches a soul the rule does not limit.
      result = decide(soul: soul, files: %w[app/models/task.rb], authors: [soul], verdict: nil, head: "", live_head: "")

      assert result.permitted?, "#{soul} must be untouched by the documentation-seat rule"
      assert_equal :unrestricted, result.code
    end
  end

  def test_refuses_a_blank_soul
    assert_equal :no_soul, decide(soul: " ").code
  end
end
