# frozen_string_literal: true

# [unit] ReviewerSelectSkip — the classifier that tells bin/reviewer-select's TWO
# exit-10 refusals apart so bin/pr-review can name the right remedy for each.
#
# THE DEFECT THIS PINS (measured 2026-09-22, PR #1537). bin/pr-review raised ONE
# hard-coded sentence for exit 10 — "another live session already holds this review …
# take the next reviewable task instead". That is the HELD arm's remedy. The other arm
# is a SELF-REVIEW refusal: nobody holds the task, the picked primary is simply in its
# AUTHOR SET, and taking the next task fixes nothing — the same refusal recurs on every
# re-run. The correct text was already on screen (the raise appends reviewer-select's
# own stderr); it sat under a lead sentence contradicting it.
#
# WHY THE DECISION LIVES IN A MODULE AND NOT IN THE SCRIPT. bin/pr-review has no
# execution harness, so every test of it reads its SOURCE — and a source test cannot see
# a DISABLED branch (test/lib/pr_review_stacked_base_test.rb records a mutant that put
# the refusal in dead code and left every assertion green). So the arm decision lives
# here, where it can be DRIVEN. The script keeps only the wiring, pinned below.
#
# THE OTHER HALF OF THE COVERAGE is test/lib/reviewer_select_test.rb, which drives the
# REAL bin/reviewer-select into BOTH refusals and asserts these markers classify its
# ACTUAL stderr. That is the cross-file coupling: this file proves the classifier reads
# the markers; that file proves the markers are what reviewer-select still prints.
#
# Run directly:  ruby -Itest test/lib/reviewer_select_skip_test.rb

require "minitest/autorun"
require_relative "../../bin/lib/reviewer_select_skip"

class ReviewerSelectSkipTest < Minitest::Test
  SLUG = "sample-task-slug"
  PR_REVIEW_SRC = File.read(File.expand_path("../../bin/pr-review", __dir__))

  # Abridged transcripts of the two refusals, each keeping its real lead phrase and
  # real remedy block. The LIVE text is asserted in reviewer_select_test.rb; these
  # stand in here so the arms can be driven without a board.
  HELD_STDERR = <<~ERR
    reviewer-select REFUSED to select for task=#{SLUG} — ALREADY UNDER REVIEW.
      Held by: carl · pr-review · session aaaaaaaa since 2026-09-22T20:15:00Z
      Move to the next reviewable task — the board picks and claims one atomically:
        bin/task claim-next-review
  ERR

  SELF_REVIEW_STDERR = <<~ERR
    reviewer-select REFUSED to select for task=#{SLUG} — THE PRIMARY BUILT IT.
      The board refused the review claim for carl: that soul is in this task's
      AUTHOR SET, so seating them is a self-review. Nothing was recorded.
        bin/task move #{SLUG} building --actor <the-real-builder>
  ERR

  # A refusal whose lead phrase this classifier does not know — what a REWORDED
  # reviewer-select produces. Deliberately carries neither marker.
  UNKNOWN_STDERR = "reviewer-select REFUSED to select for task=#{SLUG} — for reasons of its own.\n"

  # --- the arms, read off the refusal ----------------------------------------

  def test_the_two_arms_are_classified_apart
    assert_equal :held, ReviewerSelectSkip.arm(HELD_STDERR)
    assert_equal :self_review, ReviewerSelectSkip.arm(SELF_REVIEW_STDERR)
  end

  # THE CARD'S HEADLINE. Two refusals sharing exit 10 must not share one sentence:
  # their remedies are opposites, so one text is necessarily wrong for one arm.
  def test_the_two_arms_do_not_share_one_message
    refute_equal ReviewerSelectSkip.message(SLUG, HELD_STDERR),
                 ReviewerSelectSkip.message(SLUG, SELF_REVIEW_STDERR),
                 "exit 10 carries TWO refusals with OPPOSITE remedies; one message for both " \
                 "is the defect — it sends a self-review refusal at 'take the next task', " \
                 "which cannot fix it"
  end

  # --- the held arm keeps what it had ----------------------------------------

  def test_the_held_arm_keeps_the_take_the_next_task_remedy
    message = ReviewerSelectSkip.message(SLUG, HELD_STDERR)

    assert_includes message, "bin/task claim-next-review",
                    "a live peer holds this review; the move is ANOTHER task"
    refute_includes message, "--actor",
                    "nothing is wrong with this task's author set — sending the reader to " \
                    "re-stamp a builder would have them rewrite a correct record to work " \
                    "around a peer who is simply still reviewing"
  end

  # --- the self-review arm routes to the author set --------------------------

  def test_the_self_review_arm_routes_to_author_set_reconciliation
    message = ReviewerSelectSkip.message(SLUG, SELF_REVIEW_STDERR)

    assert_includes message, "AUTHOR SET",
                    "the self-review arm must name WHAT was refused: the picked primary is " \
                    "recorded as a builder of this task"
    assert_includes message, "bin/task move #{SLUG} building --actor",
                    "and the remedy that actually clears it — reconcile the author set"
  end

  # The half that makes the routing real. Naming the author set while ALSO offering the
  # held arm's remedy would leave the wrong move on screen, and it is the easier one to
  # take: `claim-next-review` costs one command, re-stamping a builder costs a decision.
  def test_the_self_review_arm_does_not_offer_the_held_arms_remedy
    message = ReviewerSelectSkip.message(SLUG, SELF_REVIEW_STDERR)

    refute_includes message, "bin/task claim-next-review",
                    "NOBODY holds this review, so taking the next task does not fix it — the " \
                    "same refusal recurs on the next run. Offering it here is the original bug"
  end

  # --- a refusal this classifier cannot read ---------------------------------

  # The arm is read from reviewer-select's LEAD PHRASE, which is a cross-file coupling:
  # a rewording there reaches here. Defaulting to the common arm would resume the exact
  # defect silently, so an unreadable refusal names BOTH arms and guesses neither.
  def test_an_unrecognized_refusal_names_both_arms_instead_of_guessing
    assert_equal :unrecognized, ReviewerSelectSkip.arm(UNKNOWN_STDERR)

    message = ReviewerSelectSkip.message(SLUG, UNKNOWN_STDERR)

    assert_includes message, "could NOT tell WHICH",
                    "an unreadable refusal must SAY it could not classify — a confident wrong " \
                    "arm is worse than an honest unknown"
    assert_includes message, ReviewerSelectSkip::HELD_MARKER,
                    "and name the held arm, with its remedy, so the reader can match it by eye"
    assert_includes message, ReviewerSelectSkip::SELF_REVIEW_MARKER,
                    "and the self-review arm too — both, because it does not know which"
    assert_includes message, "--actor",
                    "including the author-set remedy, which is the one a held-arm default would lose"
  end

  # --- every arm still reads as a SKIP ---------------------------------------

  # The property the original comment was right about and must survive the fix: exit 10
  # is a SKIP, not a failure. "failed" reads as retryable and NEITHER arm is — a held
  # task frees on its own TTL, and a self-review refusal recurs forever until the author
  # set is corrected.
  # Asserted on the LEAD, not on the whole message: the text below the lead is
  # reviewer-select's, and this property is about the sentence WE write.
  def test_every_arm_reads_as_a_skip_never_as_a_retryable_failure
    %i[held self_review unrecognized].each do |which|
      lead = ReviewerSelectSkip.lead(SLUG, which)

      assert lead.start_with?("reviewer-select SKIPPED #{SLUG}"),
             "every arm leads with the SKIP and the slug (#{which}), got: #{lead[0, 60]}"
      refute_match(/\bfail(ed|ure)\b/i, lead,
                   "a generic failure reads as something to RETRY, and re-running wins neither " \
                   "arm: a held task frees on its own TTL, and a self-review refusal recurs " \
                   "forever until the author set is corrected (#{which})")
    end
  end

  # reviewer-select's own refusal is the text that names the HOLDER or the reviewer, and
  # it was already being appended — the fix is the lead sentence above it, not a rewrite
  # of what is below. Dropping it would trade one loss of information for another.
  def test_the_refusal_itself_is_carried_below_every_lead
    [HELD_STDERR, SELF_REVIEW_STDERR, UNKNOWN_STDERR].each do |detail|
      assert_includes ReviewerSelectSkip.message(SLUG, detail), detail.strip,
                      "reviewer-select's own refusal must survive intact below the lead — it " \
                      "is what names the holder, the reviewer, and the exact commands"
    end
  end

  # --- the wiring in bin/pr-review -------------------------------------------

  # Source-pinned, and only the wiring: the DECISION is driven above. What this catches
  # is the regression that re-hard-codes a sentence at the raise.
  def test_pr_review_raises_through_the_classifier_and_hard_codes_no_arm
    body = PR_REVIEW_SRC[/def select_reviewers\b.*?\nend\n/m]
    refute_nil body, "select_reviewers body not found in bin/pr-review"

    assert_includes body, "ReviewerSelectSkip.message(slug,",
                    "the exit-10 raise must build its text through the classifier"
    refute_includes body, "another live session already holds this review",
                    "this is the hard-coded HELD sentence the card is about: it was raised for " \
                    "BOTH arms. Do not re-introduce it at the raise — the held arm's wording " \
                    "belongs in ReviewerSelectSkip.held_lead, where the self-review arm has its own"
  end

  # Exit 10 must stay ONE code. ReviewClaimCli::SKIPPED shares the number on purpose, so
  # a caller that split it would desynchronize two tools to solve a wording problem.
  def test_the_wiring_still_branches_on_one_exit_code
    body = PR_REVIEW_SRC[/def select_reviewers\b.*?\nend\n/m]

    assert_includes body, "status&.exitstatus == 10",
                    "the arm is read from the refusal TEXT, not from a new exit code — " \
                    "ReviewClaimCli::SKIPPED shares 10 deliberately"
  end
end
