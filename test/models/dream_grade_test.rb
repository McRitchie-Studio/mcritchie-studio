# frozen_string_literal: true

require "test_helper"

# [unit] DreamGrade: a session grades only a dream that fired in it, once, 0 to 2,
# naming the decision; a grade never touches a dream's status.
class DreamGradeTest < ActiveSupport::TestCase
  def fire(slug, session: "wrap-session", at: 1.hour.ago, kind: DreamHeat::KIND)
    AgentAction.create!(session_id: session, kind: kind, event_slug: slug, summary: "kept the probe read-only",
                        occurred_at: at, outcome: "ok", task_slug: "task-aaa111", mascot: "pikachu")
  end

  def grade(slug = "never-probe", score: 2, session: "wrap-session", decision: "Read the source before running it")
    DreamGrade.record!(session_id: session, dream_slug: slug, score: score, decision: decision)
  end

  test "[unit] records a grade for a dream that fired in the session, tied to its newest fire" do
    fire("never-probe", at: 2.hours.ago)
    newest = fire("never-probe", at: 1.hour.ago)

    row = grade

    assert_equal 2, row.score
    assert_equal newest.id, row.agent_action_id
    assert_equal "task-aaa111", row.task_slug
    assert_equal "pikachu", row.mascot
    assert_equal "Read the source before running it", row.decision
  end

  test "[unit] refuses a dream that did not fire in this session" do
    fire("never-probe", session: "another-session")
    fire("never-probe", kind: "bash")

    error = assert_raises(DreamGrade::NotGradable) { grade }
    assert_includes error.message, "did not fire in this session"
    assert_equal 0, DreamGrade.count
  end

  test "[unit] refuses a second grade in the session, a score outside 0..2 and a blank decision" do
    fire("never-probe")
    grade

    assert_raises(DreamGrade::NotGradable) { grade(score: 1) }
    [ 3, -1, "two", nil ].each do |score|
      assert_raises(DreamGrade::NotGradable, score.inspect) { grade(score: score, session: "s-#{score}") }
    end
    fire("never-probe", session: "quiet")
    error = assert_raises(DreamGrade::NotGradable) { grade(session: "quiet", decision: "   ") }
    assert_includes error.message, "names the decision"
    assert_equal 1, DreamGrade.count
  end

  test "[unit] the same dream graded in two sessions keeps both grades" do
    fire("never-probe", session: "one")
    fire("never-probe", session: "two")
    grade(session: "one", score: 0)
    grade(session: "two", score: 1)

    summary = DreamGrade.summary
    assert_in_delta 0.5, summary["never-probe"].mean
    assert_equal 2, summary["never-probe"].count
    assert_nil DreamGrade.summary([ "other" ])["never-probe"]
  end

  test "[unit] the database refuses a score outside 0..2 even past the model" do
    fire("never-probe")
    row = grade
    assert_raises(ActiveRecord::StatementInvalid) { row.update_column(:score, 5) }
  end
end
