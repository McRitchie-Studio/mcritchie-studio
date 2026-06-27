# frozen_string_literal: true

require "test_helper"

# Guard for the "primary owns the review lane" SOP redesign (task
# primary-owns-review-lane). The review-orchestration docs + the SOP vocabulary
# must describe the NESTED chain — Avi thin-delegates → the PRIMARY reviewer owns
# the lane, SPAWNS the LIGHT, and runs the merge into release — and must NOT
# describe the old flat-peer spawn + conductor merge. These assertions are
# deliberate tripwires: revert the model and they fail.
class ReviewLaneDocsTest < ActiveSupport::TestCase
  AGENTS = Rails.root.join("docs", "agents")

  # Markdown-emphasis-insensitive read: drop * and ` so bold/italic/code emphasis
  # can't break a phrase match, and collapse whitespace so a line-wrapped sentence
  # still matches as one run.
  def norm(rel)
    File.read(AGENTS.join(rel)).gsub(/[*`]/, "").gsub(/\s+/, " ")
  end

  test "[static] avi role.md frames Avi as a thin delegate and the primary owning the lane" do
    body = norm("agents/avi/role.md")
    assert_match(/primary reviewer/i, body, "the PRIMARY reviewer is named as the lane owner")
    assert_match(/primary[^.\n]{0,160}spawn[^.\n]{0,40}light/im, body,
      "the PRIMARY must spawn the LIGHT (the nested chain, not a flat peer spawn)")
    assert_match(/thin/i, body, "Avi's review role is now a thin delegation pre-step")
    refute_match(/\bheavy\b/i, body, "the heavy→primary rename must not regress in the docs")
  end

  test "[static] the devops-cycle runbook gives the merge to the primary, not the conductor" do
    body = norm("system/devops-cycle-design.md")
    assert_match(/primary[^.\n]{0,200}bin\/release merge/im, body,
      "the PRIMARY runs bin/release merge")
    assert_match(/primary[^.\n]{0,160}spawn[^.\n]{0,40}light/im, body,
      "the PRIMARY spawns the LIGHT as its own sub-agent")
    # The old flat-peer / conductor-merge framing must be gone.
    refute_match(/release conductor then merges each approved PR/i, body,
      "the overview must no longer hand the merge to the conductor")
    refute_match(/conductor merges (its|the) PR into/i, body,
      "no merge mechanics paragraph should attribute the per-task merge to the conductor")
  end

  # Cross-doc tripwire: a freshly-reviewed task is reviewed AND merged by the
  # PRIMARY, never by the conductor or Avi. Catches the "conductor reviews, merges,
  # and deploys" / "Avi reviews and merges" framings (incl. the §1.4 cold-start
  # block) that the per-file phrase checks above missed.
  REVIEW_DOCS = %w[
    agents/avi/role.md
    system/devops-cycle-design.md
    skills/qa-release/SKILL.md
    modules/parallel-agent-devops.md
  ].freeze

  test "[static] no review doc says the conductor (or Avi) reviews + merges a freshly-reviewed task" do
    REVIEW_DOCS.each do |rel|
      body = norm(rel)
      refute_match(/conductor reviews\b/i, body,
        "#{rel}: the conductor no longer reviews — Avi thin-delegates, the PRIMARY reviews")
      refute_match(/reviews,?\s+(and\s+)?merges/i, body,
        "#{rel}: drop 'reviews, merges' — the review AND the per-task merge are the PRIMARY's, not the conductor's/Avi's")
      refute_match(/conductor merges (its|the|each) (freshly-reviewed )?PR/i, body,
        "#{rel}: the conductor no longer runs the per-task merge — the PRIMARY does")
    end
  end

  test "[static] the qa-release SKILL describes the nested primary→light cascade" do
    body = norm("skills/qa-release/SKILL.md")
    assert_match(/nested cascade/i, body)
    assert_match(/primary[^.\n]{0,160}spawn[^.\n]{0,40}light/im, body)
    assert_match(/primary[^.\n]{0,120}bin\/release merge/im, body)
  end

  test "[static] the SOP vocabulary no longer flags the merge as a conductor divergence" do
    steps = Devops::Vocabulary.lanes.flat_map { |lane| lane[:steps] }
    assert(steps.none? { |step| step[:diverges].present? },
      "no SOP step should carry a :diverges note — the primary-owns-merge gap is resolved")
    release_branch = steps.find { |step| step[:label] == "Release Branch" }
    assert_not_nil release_branch
    assert_match(/primary/i, release_branch[:expectation], "the merge step names the PRIMARY reviewer")
    assert_match(/bin\/release merge/i, release_branch[:expectation])
  end
end
