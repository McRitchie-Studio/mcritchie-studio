require "test_helper"

# [unit] Insights::BlockMiner — turns RESOLVED QA blocks (a qa_feedback Activity
# later cleared by a resolves_feedback handoff) into disposition:"not" ActionGrade
# candidates, tied to the span that caused the defect. Covers the seeding, the
# span-linkage heuristic, idempotency, and the skip cases.
class Insights::BlockMinerTest < ActiveSupport::TestCase
  def span(task_slug:, opened_at:, seq: 0, session_id: "sess-mine", category: "Edit",
           reason_slug: "did the work", agent: nil, stage: "building")
    AgentActivity.create!(session_id: session_id, category: category, reason_slug: reason_slug,
                        task_slug: task_slug, opened_at: opened_at, seq: seq,
                        agent: agent, stage: stage)
  end

  def block(task_slug:, text:, at:)
    Activity.create!(task_slug: task_slug, activity_type: "qa_feedback", description: text, created_at: at)
  end

  def resolution(task_slug:, at:)
    Activity.create!(task_slug: task_slug, activity_type: "handoff", description: "ready again",
                     metadata: { "resolves_feedback" => true }, created_at: at)
  end

  test "[unit] seeds a not-candidate tying the block feedback to the newest pre-block span" do
    now = Time.current
    span(task_slug: "t-seed", opened_at: now - 20.minutes, seq: 0)
    newest = span(task_slug: "t-seed", opened_at: now - 10.minutes, seq: 1)
    blk = block(task_slug: "t-seed", text: "The stage transition bypasses the server guard entirely here", at: now - 5.minutes)
    resolution(task_slug: "t-seed", at: now - 1.minute)

    created = assert_difference -> { ActionGrade.seeded_candidates.count }, 1 do
      Insights::BlockMiner.mine!
    end
    cand = created.first || ActionGrade.seeded_candidates.last

    assert_equal ActionGrade::ALEX, cand.grader
    assert_equal ActionGrade::NOT, cand.disposition
    assert_equal newest.id, cand.agent_activity_id, "attributes to the newest span opened before the block"
    assert_equal blk.slug, cand.source_activity_slug
    assert_equal "The stage transition bypasses the server guard", cand.slug, "slug is the first 7 feedback words"
    assert_equal blk.description, cand.long_form, "the full block feedback is the lesson"
    assert cand.seeded_candidate?
    assert_not cand.banked, "a candidate is awaiting grade, not yet banked"
  end

  test "[unit] mines the full DETAILS as the lesson even when the block carries a summary" do
    now = Time.current
    span(task_slug: "t-split", opened_at: now - 10.minutes, seq: 0)
    blk = Activity.create!(task_slug: "t-split", activity_type: "qa_feedback",
                           description: "The stage transition bypasses the server guard entirely here",
                           metadata: { "summary" => "Stage move skips server guard" },
                           created_at: now - 5.minutes)
    resolution(task_slug: "t-split", at: now - 1.minute)

    created = assert_difference -> { ActionGrade.seeded_candidates.count }, 1 do
      Insights::BlockMiner.mine!
    end
    cand = created.first || ActionGrade.seeded_candidates.last

    assert_equal blk.description, cand.long_form, "the lesson is the full details, not the short summary"
    assert_equal "The stage transition bypasses the server guard", cand.slug, "slug still derives from the details"
  end

  test "[unit] is idempotent — a re-run seeds no duplicate for the same block" do
    now = Time.current
    span(task_slug: "t-idem", opened_at: now - 10.minutes)
    block(task_slug: "t-idem", text: "duplicate me not", at: now - 5.minutes)
    resolution(task_slug: "t-idem", at: now - 1.minute)

    Insights::BlockMiner.mine!
    assert_no_difference -> { ActionGrade.count } do
      Insights::BlockMiner.mine!
    end
  end

  test "[unit] an UNRESOLVED block (no resolving handoff) is never mined" do
    now = Time.current
    span(task_slug: "t-open", opened_at: now - 10.minutes)
    block(task_slug: "t-open", text: "still open, no handoff yet", at: now - 5.minutes)

    assert_no_difference -> { ActionGrade.count } do
      Insights::BlockMiner.mine!
    end
  end

  test "[unit] skips a resolved block with no attributable span (all its spans came after)" do
    now = Time.current
    blk = block(task_slug: "t-nospan", text: "no span before this block", at: now - 5.minutes)
    span(task_slug: "t-nospan", opened_at: now - 1.minute) # opened AFTER the block
    resolution(task_slug: "t-nospan", at: now)

    assert_no_difference -> { ActionGrade.count } do
      Insights::BlockMiner.mine!
    end
    assert_not ActionGrade.exists?(source_activity_slug: blk.slug)
  end

  test "[unit] never clobbers an already-Alex-graded span — falls back to the earlier ungraded one" do
    now = Time.current
    older  = span(task_slug: "t-graded", opened_at: now - 20.minutes, seq: 0)
    newest = span(task_slug: "t-graded", opened_at: now - 10.minutes, seq: 1)
    human = ActionGrade.create!(agent_activity: newest, grader: ActionGrade::ALEX,
                                disposition: ActionGrade::GOOD, slug: "already graded by hand")
    block(task_slug: "t-graded", text: "regression slipped through review", at: now - 5.minutes)
    resolution(task_slug: "t-graded", at: now - 1.minute)

    Insights::BlockMiner.mine!

    cand = ActionGrade.seeded_candidates.last
    assert_equal older.id, cand.agent_activity_id, "skips the graded newest span, uses the earlier ungraded one"
    assert_equal "already graded by hand", human.reload.slug, "the human grade is untouched"
  end

  test "[unit] skips reviewer spans opened before the block and attributes to builder work" do
    now = Time.current
    builder = span(task_slug: "t-reviewer", opened_at: now - 20.minutes, seq: 0,
                   category: "Edit", reason_slug: "build the feature", agent: nil,
                   stage: "building")
    reviewer = span(task_slug: "t-reviewer", opened_at: now - 2.minutes, seq: 1,
                    category: "Verify", reason_slug: "review the PR", agent: "shannon",
                    stage: "submitted")
    block(task_slug: "t-reviewer", text: "review caught a regression", at: now - 1.minute)
    resolution(task_slug: "t-reviewer", at: now)

    Insights::BlockMiner.mine!

    cand = ActionGrade.seeded_candidates.last
    assert_equal builder.id, cand.agent_activity_id, "reviewer spans should not become the mined defect target"
    assert_not_equal reviewer.id, cand.agent_activity_id
  end

  test "[unit] two resolved blocks on one task map to two distinct spans (no collision)" do
    now = Time.current
    s0 = span(task_slug: "t-two", opened_at: now - 40.minutes, seq: 0)
    span(task_slug: "t-two", opened_at: now - 30.minutes, seq: 1)
    s2 = span(task_slug: "t-two", opened_at: now - 15.minutes, seq: 2)

    block(task_slug: "t-two", text: "first defect caught by QA", at: now - 35.minutes)
    resolution(task_slug: "t-two", at: now - 32.minutes)
    block(task_slug: "t-two", text: "second defect caught by QA", at: now - 10.minutes)
    resolution(task_slug: "t-two", at: now - 5.minutes)

    assert_difference -> { ActionGrade.seeded_candidates.count }, 2 do
      Insights::BlockMiner.mine!
    end

    event_ids = ActionGrade.seeded_candidates.pluck(:agent_activity_id)
    assert_equal [s0.id, s2.id].sort, event_ids.sort, "earlier block -> s0, later block -> newest ungraded s2"
  end

  test "[unit] scopes to one task when a task_slug is given" do
    now = Time.current
    span(task_slug: "t-a", opened_at: now - 10.minutes)
    block(task_slug: "t-a", text: "defect in task a", at: now - 5.minutes)
    resolution(task_slug: "t-a", at: now - 1.minute)

    span(task_slug: "t-b", opened_at: now - 10.minutes)
    block(task_slug: "t-b", text: "defect in task b", at: now - 5.minutes)
    resolution(task_slug: "t-b", at: now - 1.minute)

    Insights::BlockMiner.mine!(task_slug: "t-a")

    slugs = ActionGrade.seeded_candidates.map { |g| g.agent_activity.task_slug }
    assert_equal ["t-a"], slugs.uniq, "only the scoped task's block is mined"
  end
end
