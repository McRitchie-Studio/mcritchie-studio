# frozen_string_literal: true

require "test_helper"

# PRIOR ART on a finding — the three states, and specifically the one that makes
# them worth having: `unknown` must be a RECORDED answer ("nobody looked"), never
# an absence a reader can fill in as "none found". The incident this guards
# against: finding-6a5fdcd157b3 asserted turf-monster was "the first consumer
# where the iframe actually renders" when TM's deleted view had carried the
# identical unsandboxed iframe all along — net exposure change zero, urgency
# inflated, a same-day ship implicated for a long-standing defect.
class TriageFindingTest < ActiveSupport::TestCase
  test "[unit] generates a finding slug on create" do
    finding = TriageFinding.create!(title: "Reconciler could report unreadable rows")
    assert_match(/\Afinding-[0-9a-f]{12}\z/, finding.slug)
    assert_equal "open", finding.status
  end

  test "[unit] rejects an unknown status" do
    finding = TriageFinding.new(title: "A finding", status: "someday")
    refute finding.valid?
    assert finding.errors[:status].any?
  end

  test "[unit] requires a title" do
    refute TriageFinding.new.valid?
  end

  test "[unit] promote! stamps linkage and leaves the inbox" do
    finding = TriageFinding.create!(title: "Cap drilldown actions")
    task = Task.create!(title: "Cap Drilldown Actions", stage: "designed")
    finding.promote!(task)

    assert_equal "promoted", finding.reload.status
    assert_equal task.slug, finding.promoted_task_slug
    assert_not_nil finding.resolved_at
    refute_includes TriageFinding.open_findings, finding
  end

  test "[unit] dismiss! retires the finding without a task" do
    finding = TriageFinding.create!(title: "Stale credential note")
    finding.dismiss!

    assert_equal "dismissed", finding.reload.status
    assert_nil finding.promoted_task_slug
    assert_not_nil finding.resolved_at
  end

  # [unit] THE CENTRAL ASSERTION. A finding filed without a word about prior art
  # is stored as "unknown", not NULL and not "none" — the distinction is the
  # whole feature, so it is pinned at the persistence layer, not just the render.
  test "[unit] a finding filed with no prior-art answer records unknown, not nil" do
    finding = TriageFinding.create!(title: "Preview iframe has no sandbox")

    assert_equal "unknown", finding.reload.prior_art
    refute_nil finding.prior_art, "unknown must be a recorded state, never a blank"
    refute finding.prior_art_investigated?
  end

  # [unit] "we looked and found nothing" is a DIFFERENT record from "nobody
  # looked". If these two ever collapse into one value the column is decoration.
  test "[unit] none and unknown are distinct states" do
    looked = TriageFinding.create!(title: "Checked surface", prior_art: "none")
    did_not = TriageFinding.create!(title: "Unchecked surface")

    refute_equal looked.prior_art, did_not.prior_art
    assert looked.prior_art_investigated?
    refute did_not.prior_art_investigated?
    assert_match(/none found/i, looked.prior_art_summary)
    assert_match(/NOT INVESTIGATED/, did_not.prior_art_summary)
  end

  # [unit] `found` without evidence is the blank trap wearing a badge: it claims
  # the check happened while recording nothing anyone can verify.
  test "[unit] found prior art without a note is rejected" do
    finding = TriageFinding.new(title: "Claims a check it cannot show", prior_art: "found")

    refute finding.valid?
    assert_includes finding.errors[:prior_art_note].join, "required"
  end

  test "[unit] found prior art with a note is accepted and summarised verbatim" do
    note = "TM's deleted app/views/emails/preview.html.erb carried the same iframe since 2025-11"
    finding = TriageFinding.create!(title: "Preview iframe has no sandbox",
                                    prior_art: "found", prior_art_note: note)

    assert finding.prior_art_investigated?
    assert_includes finding.prior_art_summary, note
  end

  # [unit] an unparseable claim must FAIL, not be coerced into a friendlier
  # state. A prior-art value the board could not read must never become a
  # prior-art claim the board invented.
  test "[unit] an out-of-range prior-art state is refused" do
    finding = TriageFinding.new(title: "Bad state", prior_art: "probably-fine")

    refute finding.valid?
    assert_includes finding.errors[:prior_art].join, "is not included"
  end

  # [unit] the uninvestigated context carries an INSTRUCTION, because the failure
  # mode is a downstream agent inheriting a framing the finding never established.
  test "[unit] uninvestigated prior-art context tells the reader to go look" do
    context = TriageFinding.create!(title: "Unchecked surface").prior_art_context

    assert_match(/NOT INVESTIGATED/, context)
    assert_match(/BEFORE assuming this change introduced it/, context)
    assert_match(/deleted files included/, context)
  end

  test "[unit] an investigated finding's context is just the answer, with no nag" do
    context = TriageFinding.create!(title: "Checked surface", prior_art: "none").prior_art_context

    assert_match(/none found/i, context)
    refute_match(/BEFORE assuming/, context)
  end
end
