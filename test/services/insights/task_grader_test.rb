require "test_helper"

# [unit] Insights::TaskGrader — grades a shipped task ONCE from board facts, trips a
# threshold from config/learning_loop.yml, and writes AT MOST ONE learning line
# (task note + banked ActionGrade). No LLM call, no GitHub call (the PR reader is
# injected).
class Insights::TaskGraderTest < ActiveSupport::TestCase
  NoLines = Struct.new(:lines) do
    def lines_for(_url) = lines
  end

  CONFIG = {
    "bounces" => 2, "gate_failures" => 3, "percentile" => 90,
    "trailing_window" => 100, "min_samples" => 3,
    "priority" => %w[escalation bounces gate_failures cost build_cycle review_cycle]
  }.freeze

  def shipped_task(slug, at: Time.current, cost: nil, build_hours: 1, review_hours: 1, po: "small")
    task = Task.create!(title: "grade #{slug} task", slug: slug, po_size: po)
    travel_to(at - (build_hours + review_hours).hours) { task.update!(stage: "building") }
    travel_to(at - review_hours.hours) { task.update!(stage: "submitted") }
    task.task_events.create!(to_stage: "submitted", occurred_at: at - review_hours.hours, cost: cost, kind: TaskEvent::CHECKPOINT) if cost
    travel_to(at) { task.update!(stage: "shipped") }
    task.reload
  end

  def bounce(task, text, kind: "rework")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", description: text,
                     metadata: { "kind" => kind })
  end

  def gate_fail(task, key, attempt)
    GateRun.create!(subject_type: "task", subject_slug: task.slug, key: key, attempt: attempt,
                    started_at: Time.current, finished_at: Time.current, success: false)
  end

  def grader(task, baseline: nil, lines: nil)
    baseline ||= Insights::TaskGrader::Baseline.new({}, config: CONFIG)
    Insights::TaskGrader.new(task, baseline: baseline, pr_reader: NoLines.new(lines), config: CONFIG)
  end

  test "[unit] gathers the facts: sizes, bounces, gate failures, cycle times, cost, lines" do
    task = shipped_task("grade-facts", cost: BigDecimal("3.5"), build_hours: 2, review_hours: 3, po: "small")
    task.update_column(:actual_size, "large")
    bounce(task, "Missing the nil guard on the grader")
    bounce(task, "Blocked on the dev database", kind: "environment")
    gate_fail(task, "g1_cert", 1)

    facts = grader(task, lines: 42).assessment.facts

    assert_equal "small", facts["po_size"]
    assert_equal "large", facts["actual_size"]
    assert_equal 2, facts["size_delta"], "small → large is two sizes over the forecast"
    assert_equal 1, facts["bounces"], "an environment block is not a bounce"
    assert_equal({ "g1_cert" => 1 }, facts["gate_failures"])
    assert_equal 2 * 3600, facts["build_seconds"]
    assert_equal 3 * 3600, facts["review_seconds"]
    assert_in_delta 3.5, facts["cost"], 0.001
    assert_equal 42, facts["lines_changed"]
  end

  test "[unit] nothing tripped records nothing to learn and writes no note or grade" do
    task = shipped_task("grade-quiet")
    bounce(task, "One small fix")

    grade = assert_no_difference -> { Activity.where(activity_type: "comment").count } do
      assert_no_difference -> { ActionGrade.count } do
        grader(task).grade!
      end
    end

    assert_equal TaskGrade::NOTHING_TO_LEARN, grade.verdict
    assert_nil grade.learning
    assert_empty grade.tripped
  end

  test "[unit] two bounces trip and write ONE learning on the task and in the feed" do
    task = shipped_task("grade-bounced")
    span = AgentActivity.create!(session_id: "s-grade", category: "Edit", reason_slug: "built it",
                                 task_slug: task.slug, opened_at: 1.hour.ago, seq: 0)
    bounce(task, "Missed the regression test")
    bounce(task, "Still no regression test")

    grade = grader(task).grade!

    assert_equal TaskGrade::LEARNING, grade.verdict
    assert_equal ["bounces"], grade.tripped
    assert_match(/\Agrade-bounced: bounced 2 times — Missed the regression test; Still no regression test\z/, grade.learning)

    note = grade.note_activity
    assert_equal "comment", note.activity_type
    assert_equal "learning", note.metadata["kind"]
    assert_equal ActionGrade::XAN, note.agent_slug

    banked = grade.action_grade
    assert banked.banked, "the learning is banked into the insight feed"
    assert_equal ActionGrade::NOT, banked.disposition
    assert_equal span.id, banked.agent_activity_id
    assert_equal note.slug, banked.source_activity_slug
    assert_includes ActionGrade.insight_feed.map(&:id), banked.id
    assert_equal task.slug, banked.to_insight["task_slug"]
  end

  test "[unit] many tripped thresholds still write exactly one line, highest priority first" do
    task = shipped_task("grade-capped")
    AgentActivity.create!(session_id: "s-cap", category: "Edit", reason_slug: "built", task_slug: task.slug,
                          opened_at: 1.hour.ago, seq: 0)
    3.times { |i| bounce(task, "bounce #{i}") }
    3.times { |i| gate_fail(task, "dor", i + 1) }
    Activity.create!(task_slug: task.slug, activity_type: "comment",
                     description: "RULING: OVERRULE — the reviewer misread the guard. Measured: green.")

    grade = assert_difference -> { ActionGrade.count } => 1, -> { Activity.where(activity_type: "comment").count } => 1 do
      grader(task).grade!
    end

    assert_equal %w[escalation bounces gate_failures], grade.tripped
    assert_match(/\Agrade-capped: escalated to the operator — RULING: OVERRULE/, grade.learning)
    assert_match(/\(also tripped: bounces, gate_failures\)\z/, grade.learning)
  end

  test "[unit] an Escalated: block trips escalation and is not counted as a bounce" do
    task = shipped_task("grade-escalated")
    Activity.create!(task_slug: task.slug, activity_type: "qa_feedback", description: "details",
                     metadata: { "kind" => "dependency", "summary" => "Escalated: reviewer and builder disagree" })

    result = grader(task).assessment
    assert_equal 0, result.facts["bounces"]
    assert_equal ["escalation"], result.tripped.map { |t| t[:key] }
    assert_match(/Escalated: reviewer and builder disagree/, result.learning)
  end

  test "[unit] a gate trips only at three failures" do
    task = shipped_task("grade-gates")
    2.times { |i| gate_fail(task, "g1_cert", i + 1) }
    assert_nil grader(task).assessment.learning, "two failures is under the threshold"

    gate_fail(task, "g1_cert", 3)
    assert_match(/gate g1_cert failed repeatedly — g1_cert failed 3x/, grader(task).assessment.learning)
  end

  test "[unit] cost and cycle time trip above the trailing p90, and a thin sample skips" do
    task = shipped_task("grade-costly", cost: BigDecimal("50"), build_hours: 30)
    baseline = Insights::TaskGrader::Baseline.new(
      { "cost" => [1, 2, 3, 4, 5], "build_cycle" => [3600, 7200, 7200, 7200, 10_800], "review_cycle" => [] },
      config: CONFIG
    )
    keys = grader(task, baseline: baseline).assessment.tripped.map { |t| t[:key] }
    assert_equal %w[cost build_cycle], keys, "review has no sample, so it cannot trip"

    thin = Insights::TaskGrader::Baseline.new({ "cost" => [1, 0, 0, 0, 0] }, config: CONFIG)
    assert_nil thin.percentile("cost"), "a window of zeros is not a sample"
    assert_nil grader(task, baseline: thin).assessment.learning
  end

  test "[unit] Baseline measures the trailing window of shipped tasks, excluding the graded one" do
    shipped_task("grade-base-a", cost: BigDecimal("2"))
    shipped_task("grade-base-b", cost: BigDecimal("4"))
    target = shipped_task("grade-base-c", cost: BigDecimal("400"))

    baseline = Insights::TaskGrader::Baseline.build(exclude: target.slug, config: CONFIG.merge("min_samples" => 2))
    assert_equal 2, baseline.to_h["cost"]["n"]
    assert_in_delta 4.0, baseline.percentile("cost"), 0.001
  end

  test "[unit] an archived task that shipped still counts as shipped; one never shipped does not" do
    swept = shipped_task("grade-swept")
    swept.update!(stage: "archived")
    abandoned = Task.create!(title: "grade abandoned task", slug: "grade-abandoned")
    abandoned.update!(stage: "archived")

    slugs = Insights::TaskGrader.shipped_tasks.pluck(:slug)
    assert_includes slugs, "grade-swept", "archive-shipped sweeps shipped tasks into archived"
    assert_not_includes slugs, "grade-abandoned", "an abandoned task never shipped"
    assert Insights::TaskGrader.grade!("grade-swept", pr_reader: NoLines.new(nil))
    assert_nil Insights::TaskGrader.grade!("grade-abandoned")
  end

  test "[unit] grade! is once per task: a second call returns the first grade" do
    task = shipped_task("grade-once")
    first = Insights::TaskGrader.grade!(task.slug, pr_reader: NoLines.new(nil))
    assert_no_difference -> { TaskGrade.count } do
      assert_equal first, Insights::TaskGrader.grade!(task.slug, pr_reader: NoLines.new(nil))
    end
  end

  test "[unit] grade! skips a task that has not shipped" do
    task = Task.create!(title: "grade not shipped task", stage: "building")
    assert_nil Insights::TaskGrader.grade!(task.slug)
  end

  test "[unit] a learning with no narrated activity stays on the task and says the feed missed it" do
    task = shipped_task("grade-no-anchor")
    2.times { |i| bounce(task, "bounce #{i}") }

    grade = grader(task).grade!
    assert grade.note_activity, "the task note is still written"
    assert_nil grade.action_grade
    assert_equal "no narrated activity to bank against", grade.facts["feed"]
  end

  test "[unit] PrLines sums additions and deletions and reads nil on any failure" do
    client = Object.new
    def client.get(path) = path.end_with?("/7") ? { "additions" => 10, "deletions" => 5 } : raise("404")

    reader = Insights::TaskGrader::PrLines.new(client: client)
    assert_equal 15, reader.lines_for("https://github.com/McRitchie-Studio/mcritchie-studio/pull/7")
    assert_nil reader.lines_for("https://github.com/McRitchie-Studio/mcritchie-studio/pull/8")
    assert_nil reader.lines_for(nil)
  end

  test "[unit] the shipped config carries every threshold the grader reads" do
    config = Insights::TaskGrader.config
    %w[bounces gate_failures percentile trailing_window min_samples priority].each do |key|
      assert config.key?(key), "config/learning_loop.yml is missing #{key}"
    end
  end
end
