# frozen_string_literal: true

require "test_helper"

# [unit] A build CLAIM records WHO built the task, so the reviewer pool can
# exclude them.
#
# THE MEASURED FAILURE (2026-08-28, a full review sitting): built_by was blank on
# SIX consecutive tasks, `bin/reviewer-select` refused on every one, and two
# separate reviewers picked their light BY HAND — leaving the no-self-review
# property unverified across the whole sitting. That guard is the only thing
# standing between an agent and reviewing its own PR.
#
# The mechanism was already right. Task#enforce_builder_stamp keys on the build
# CLAIM (not the stage change, fixed 2026-08-13) and Task#builder_to_stamp reads
# Current.task_event_actor first. What was wrong was the VALUE the CLI sent: a
# session id, which can never match SOUL_SLUG, so rule 1 landed on an unusable
# actor and rules 2-3 found nothing either.
class BuilderStampFromClaimTest < ActiveSupport::TestCase
  def claim!(task, actor:)
    Current.task_event_actor = actor
    task.update!(stage: "building")
    task.reload
  ensure
    Current.task_event_actor = nil
  end

  test "a soul actor on the build claim is recorded as the builder" do
    task = Task.create!(title: "Soul Claim Probe", stage: "designed", metadata: { "devops" => {} })

    claim!(task, actor: "carl")

    assert_equal "carl", task.metadata.dig("devops", "built_by")
  end

  test "a session id is NOT mistaken for a builder" do
    # The exact shape that produced six blank tasks. A session identifier is not
    # a soul and must not be stamped as one — the pool is soul-keyed, so a
    # session id there would exclude nobody while LOOKING recorded, which is
    # worse than blank.
    task = Task.create!(title: "Session Claim Probe", stage: "designed", metadata: { "devops" => {} })

    claim!(task, actor: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b")

    assert_nil task.metadata.dig("devops", "built_by"),
               "a session id must leave built_by blank, not masquerade as a builder"
  end

  test "a recorded builder survives a wholesale devops replace" do
    # The API route replaces the devops subhash whole, so a later partial PATCH
    # that never mentions built_by would otherwise DELETE the record of who built
    # the task.
    task = Task.create!(title: "Builder Defend Probe", stage: "designed", metadata: { "devops" => {} })
    claim!(task, actor: "shannon")

    task.update!(metadata: { "devops" => { "branch" => "feat/x" } })

    assert_equal "shannon", task.reload.metadata.dig("devops", "built_by")
  end

  test "a build claim never re-points an existing builder to a non-soul" do
    task = Task.create!(title: "No Repoint Probe", stage: "designed", metadata: { "devops" => {} })
    claim!(task, actor: "jasper")

    claim!(task, actor: "019f3b0c-3a8d-73b1-9e8b-f380e11fb91b")

    assert_equal "jasper", task.metadata.dig("devops", "built_by")
  end
end
