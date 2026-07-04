# frozen_string_literal: true

require "test_helper"

# Guard for the review-lane SOP: Avi thin-delegates → the PRIMARY reviewer owns
# the lane and SPAWNS the LIGHT (the nested chain, never a flat peer spawn), and
# — since move-release-assembly-to-steffon (2026-07-03) — review is REVIEW-ONLY:
# the merge belongs to Steffon's self-healing qa-deploy sweep, which flips
# members assembled on QA-green. These assertions are deliberate tripwires:
# revert the model and they fail.
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

  test "[static] the devops-cycle runbook gives the merge to Steffon's sweep — review is review-only" do
    body = norm("system/devops-cycle-design.md")
    assert_match(/review-only/i, body, "review stops at reviewed — the 2026-07-03 contract")
    assert_match(/self-healing/i, body, "Steffon's qa-deploy is the self-healing sweep")
    assert_match(/sweep[^.\n]{0,300}merged: "release"/im, body,
      "the sweep stamps the merged git-location (the crash-recovery signal)")
    assert_match(/primary[^.\n]{0,160}spawn[^.\n]{0,40}light/im, body,
      "the PRIMARY spawns the LIGHT as its own sub-agent")
    # The old primary-owns-merge framing must be gone (reversed 2026-07-03).
    refute_match(/primary[^.\n]{0,120}runs bin\/release merge/im, body,
      "the PRIMARY no longer runs the merge — review is review-only; Steffon sweeps")
    refute_match(/release conductor then merges each approved PR/i, body,
      "the overview must not regress to the pre-2026-07-02 conductor-merge framing either")
  end

  # Cross-doc tripwire: review and merge are SEPARATE hands — the PRIMARY
  # reviews (review-only), Steffon's sweep merges. Nobody "reviews + merges" in
  # one breath. Catches the "conductor reviews, merges, and deploys" / "Avi
  # reviews and merges" / "primary reviews and merges" framings (incl. the §1.4
  # cold-start block) that the per-file phrase checks above missed.
  REVIEW_DOCS = %w[
    agents/avi/role.md
    system/devops-cycle-design.md
    skills/qa-release/SKILL.md
    modules/parallel-agent-devops.md
  ].freeze

  test "[static] no review doc says any ONE hand reviews + merges a freshly-reviewed task" do
    REVIEW_DOCS.each do |rel|
      body = norm(rel)
      refute_match(/conductor reviews\b/i, body,
        "#{rel}: the conductor never reviews — Avi thin-delegates, the PRIMARY reviews")
      refute_match(/reviews,?\s+(and\s+)?merges/i, body,
        "#{rel}: drop 'reviews, merges' — review (PRIMARY) and merge (Steffon's sweep) are separate hands")
      refute_match(/primary[^.\n]{0,120}runs bin\/release merge/im, body,
        "#{rel}: the PRIMARY no longer merges — review-only since 2026-07-03; the sweep owns it")
    end
  end

  test "[static] the qa-release SKILL describes the nested primary→light cascade, review-only" do
    body = norm("skills/qa-release/SKILL.md")
    assert_match(/nested cascade/i, body)
    assert_match(/primary[^.\n]{0,160}spawn[^.\n]{0,40}light/im, body)
    assert_match(/review-only/i, body, "the SKILL states the review-only contract")
    assert_match(/self-healing/i, body, "…and hands the merge to Steffon's self-healing sweep")
  end

  test "[static] the SOP vocabulary hands the merge to Steffon's sweep (no divergence notes)" do
    steps = Devops::Vocabulary.lanes.flat_map { |lane| lane[:steps] }
    assert(steps.none? { |step| step[:diverges].present? },
      "no SOP step should carry a :diverges note — the model matches the SOP")
    release_branch = steps.find { |step| step[:label] == "Release Branch" }
    assert_not_nil release_branch
    assert_match(/sweep/i, release_branch[:expectation], "the merge step is the self-healing sweep's")
    assert_match(/bin\/release (prepare|merge)/i, release_branch[:expectation])
    refute_match(/primary/i, release_branch[:expectation],
      "the merge no longer belongs to the PRIMARY reviewer — review is review-only")
  end
end
