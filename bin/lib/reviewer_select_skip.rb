# frozen_string_literal: true

# WHICH ARM OF reviewer-select's EXIT 10 IS THIS, AND WHAT DO YOU DO ABOUT IT?
#
# bin/reviewer-select collapses TWO refusals onto exit 10 (REVIEW_CLAIM_SKIPPED), and
# ReviewClaimCli::SKIPPED deliberately shares the number, so the CODE is not split and
# must not be. Reading exit 10 as a SKIP rather than a failure is also correct and stays
# — a generic "failed" reads as retryable, and neither arm is. What was wrong is the
# WORDING, because the two arms carry OPPOSITE remedies:
#
#   HELD         a DIFFERENT live session already holds this task's review claim.
#                Nobody is at fault; the move is another task.
#                Remedy: bin/task claim-next-review (or ask the holder to release).
#   SELF_REVIEW  the BOARD refused the claim because the picked primary is in this
#                task's AUTHOR SET (the claim-side no-self-review backstop).
#                NOBODY holds the task. Taking the next task does NOT fix it — the
#                same refusal recurs on every re-run.
#                Remedy: reconcile the author set (bin/task move <slug> building
#                --actor <the-real-builder>).
#
# bin/pr-review used to hard-code the HELD lead sentence for BOTH arms, so a self-review
# refusal was sent at the held arm's remedy and the condition survived the "fix". The
# correct text was already on screen: that raise appends reviewer-select's own stderr,
# so the right remedy sat directly below a lead sentence contradicting it.
#
# THE SIGNAL, and its one weakness. bin/reviewer-select exits before it prints any
# machine-readable decision, so a refusal carries no disposition field — the arm is read
# from the refusal's own LEAD PHRASE. That is a CROSS-FILE COUPLING: reword
# refuse_self_review! and a classifier that defaulted to HELD would silently resume the
# original bug. Two things hold it closed:
#
#   1. An output matching NEITHER marker classifies :unrecognized, which names BOTH arms
#      rather than guessing one. A drifted marker then produces a loud, honest message
#      instead of a confident wrong one.
#   2. test/lib/reviewer_select_test.rb drives the REAL bin/reviewer-select into each
#      refusal and asserts these markers classify its actual stderr — so a rewording
#      reds a test in the same repo rather than regressing a message nobody re-reads.
module ReviewerSelectSkip
  # bin/reviewer-select#refuse_self_review!'s lead phrase.
  SELF_REVIEW_MARKER = "THE PRIMARY BUILT IT."
  # bin/reviewer-select#refuse_held!'s lead phrase.
  HELD_MARKER = "ALREADY UNDER REVIEW."

  module_function

  # :self_review · :held · :unrecognized — read from reviewer-select's combined output.
  # :unrecognized is NOT a fallback to the common case on purpose: the two remedies are
  # opposites, so guessing wrong sends the reader at a fix that cannot work, which is
  # precisely the defect this module exists to end.
  def arm(detail)
    text = detail.to_s
    return :self_review if text.include?(SELF_REVIEW_MARKER)
    return :held if text.include?(HELD_MARKER)

    :unrecognized
  end

  # The operator-facing text bin/pr-review raises for exit 10. Every arm leads with
  # "SKIPPED <slug>" (never "failed": this is not retryable) and ends with
  # reviewer-select's own refusal, which names the holder or the author set.
  def message(slug, detail)
    "#{lead(slug, arm(detail))}\n#{detail.to_s.strip}"
  end

  def lead(slug, which)
    case which
    when :self_review then self_review_lead(slug)
    when :held then held_lead(slug)
    else unrecognized_lead(slug)
    end
  end

  def held_lead(slug)
    "reviewer-select SKIPPED #{slug} — ALREADY UNDER REVIEW: another live session " \
      "already holds this review. Seating a second pair here IS the two-primaries bug. " \
      "Do NOT review it here; take the next reviewable task instead " \
      "(bin/task claim-next-review):"
  end

  def self_review_lead(slug)
    "reviewer-select SKIPPED #{slug} — THE PRIMARY BUILT IT: the board refused the " \
      "review claim because the picked primary is in this task's AUTHOR SET. NOBODY " \
      "holds this review, so taking the next task does NOT fix it — the same refusal " \
      "recurs. Reconcile the author set instead: `bin/task show #{slug} --verbose` for " \
      "what the board records, then `bin/task move #{slug} building --actor " \
      "<the-real-builder>`:"
  end

  def unrecognized_lead(slug)
    "reviewer-select SKIPPED #{slug} (exit 10) — and this session could NOT tell WHICH " \
      "refusal it was, so it will not guess: the two arms have OPPOSITE remedies. " \
      "\"#{HELD_MARKER}\" means a live holder — move on with bin/task " \
      "claim-next-review. \"#{SELF_REVIEW_MARKER}\" means an author-set collision — nobody " \
      "holds it, moving on repeats it, and the fix is `bin/task move #{slug} building " \
      "--actor <the-real-builder>`. Do NOT review it here; read reviewer-select's own " \
      "refusal below and follow the remedy IT names:"
  end
end
