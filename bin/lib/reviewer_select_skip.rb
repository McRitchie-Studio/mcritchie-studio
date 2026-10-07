# frozen_string_literal: true

require "json"

# WHICH ARM OF reviewer-select's EXIT 10 IS THIS, AND WHAT DO YOU DO ABOUT IT?
#
# bin/reviewer-select collapses TWO refusals onto exit 10 (REVIEW_CLAIM_SKIPPED), and
# ReviewClaimCli::SKIPPED deliberately shares the number, so the exit status is not
# split. Reading exit 10 as a SKIP rather than a failure is correct — a generic
# "failed" reads as retryable, and neither arm is. The two arms carry OPPOSITE
# remedies:
#
#   held         a DIFFERENT live session already holds this task's review claim.
#                Nobody is at fault; the move is another task.
#                Remedy: bin/task claim-next-review (or ask the holder to release).
#   self_review  the BOARD refused the claim because the picked primary is in this
#                task's AUTHOR SET (the claim-side no-self-review backstop).
#                NOBODY holds the task. Taking the next task does NOT fix it — the
#                same refusal recurs on every re-run.
#                Remedy: reconcile the author set (bin/task move <slug> building
#                --actor <the-real-builder>).
#
# THE SIGNAL IS A CODE, NOT A PHRASE (guard catalog row 6.2). Under --json each arm
# prints one stdout line, {"skipped":true,"skip_code":"held"|"self_review",...}, before
# it exits 10, so rewording a refusal cannot change which arm a caller reads. A refusal
# with no code (a reviewer-select run without --json) classifies :unrecognized, which
# names BOTH arms rather than guessing one.
module ReviewerSelectSkip
  # bin/reviewer-select's SKIP_CODE_HELD and SKIP_CODE_SELF_REVIEW, as the arms they name.
  CODES = { "held" => :held, "self_review" => :self_review }.freeze

  module_function

  # :self_review · :held · :unrecognized — read from the skip code reviewer-select
  # printed. :unrecognized is NOT a fallback to the common case on purpose: the two
  # remedies are opposites, so guessing wrong sends the reader at a fix that cannot work.
  def arm(detail)
    CODES.fetch(skip_code(detail), :unrecognized)
  end

  # The skip_code on the first JSON skip line in +detail+, or nil.
  def skip_code(detail)
    detail.to_s.each_line do |line|
      record = skip_record(line)
      return record["skip_code"].to_s if record
    end
    nil
  end

  def skip_record(line)
    text = line.strip
    return nil unless text.start_with?("{")

    parsed = JSON.parse(text)
    parsed.is_a?(Hash) && parsed["skipped"] == true && parsed.key?("skip_code") ? parsed : nil
  rescue JSON::ParserError
    nil
  end

  # The operator-facing text bin/pr-review raises for exit 10. Every arm leads with
  # "SKIPPED <slug>" (never "failed": this is not retryable) and ends with
  # reviewer-select's own refusal, which names the holder or the author set. The
  # machine-readable skip line is dropped from the quoted refusal.
  def message(slug, detail)
    quoted = detail.to_s.each_line.reject { |line| skip_record(line) }.join
    "#{lead(slug, arm(detail))}\n#{quoted.strip}"
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
    "reviewer-select SKIPPED #{slug} (exit 10) — and it printed no skip code, so this " \
      "session will not guess which refusal it was: the two arms have OPPOSITE remedies. " \
      "ALREADY UNDER REVIEW means a live holder — move on with bin/task " \
      "claim-next-review. THE PRIMARY BUILT IT means an author-set collision — nobody " \
      "holds it, moving on repeats it, and the fix is `bin/task move #{slug} building " \
      "--actor <the-real-builder>`. Do NOT review it here; read reviewer-select's own " \
      "refusal below and follow the remedy IT names:"
  end
end
