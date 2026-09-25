require "test_helper"

# [integration] The learning loop wired end to end: the `→ shipped` transition
# enqueues TaskGradingJob after commit, the job grades once and never raises, and
# the backfill prints its table in dry run without writing a thing.
class TaskGradingLoopTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  NoLines = Struct.new(:x) do
    def lines_for(_url) = nil
  end

  def ship(slug, bounces: 0)
    task = Task.create!(title: "loop #{slug} task", slug: slug, stage: "assembled")
    bounces.times do |i|
      Activity.create!(task_slug: slug, activity_type: "qa_feedback", description: "bounce #{i}",
                       metadata: { "kind" => "rework" })
    end
    AgentActivity.create!(session_id: "s-#{slug}", category: "Edit", reason_slug: "built", task_slug: slug,
                          opened_at: 1.hour.ago, seq: 0)
    task.ship!
    task
  end

  test "[integration] shipping enqueues grading; other moves do not" do
    task = Task.create!(title: "loop enqueue task", stage: "building")
    assert_no_enqueued_jobs(only: TaskGradingJob) { task.update!(stage: "submitted") }

    task.update!(stage: "assembled")
    assert_enqueued_with(job: TaskGradingJob, args: [task.slug]) { task.ship! }
  end

  test "[integration] an enqueue failure never blocks the ship" do
    task = Task.create!(title: "loop enqueue fails", stage: "assembled")
    TaskGradingJob.stub(:perform_later, ->(*) { raise "redis down" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        task.ship!
      end
    end
    assert_equal "shipped", task.reload.stage
  end

  test "[integration] the job grades a shipped task once and banks its learning" do
    task = perform_enqueued_jobs(only: TaskGradingJob) { ship("loop-graded", bounces: 2) }

    grade = task.reload.task_grade
    assert grade, "the ship hook graded the task"
    assert_equal TaskGrade::LEARNING, grade.verdict
    assert grade.action_grade.banked

    assert_no_difference -> { TaskGrade.count } do
      TaskGradingJob.perform_now(task.slug)
    end
  end

  test "[integration] a grading failure is logged, not raised" do
    task = Task.create!(title: "loop grade fails", stage: "assembled")
    task.ship!
    Insights::TaskGrader.stub(:grade!, ->(*) { raise "boom" }) do
      assert_difference -> { ErrorLog.count }, 1 do
        TaskGradingJob.perform_now(task.slug)
      end
    end
  end

  test "[integration] the dry-run backfill prints a row per task and writes nothing" do
    ship("loop-dry-a", bounces: 2)
    ship("loop-dry-b")
    io = StringIO.new

    rows = assert_no_difference [-> { TaskGrade.count }, -> { ActionGrade.count }, -> { Activity.count }] do
      Insights::TaskGrader::Backfill.run(limit: 2, live: false, io: io, pr_reader: NoLines.new)
    end

    out = io.string
    assert_match(/DRY RUN \(nothing written\)/, out)
    assert_match(/^loop-dry-a .*LEARN loop-dry-a: bounced 2 times/, out)
    assert_match(/^loop-dry-b .*nothing to learn/, out)
    assert_match(/1 of 2 would write a learning/, out)
    assert_equal %w[loop-dry-b loop-dry-a], rows.map { |r| r[:slug] }, "newest ship first"
  end

  test "[integration] the live backfill grades each ungraded task once" do
    ship("loop-live")
    io = StringIO.new
    assert_difference -> { TaskGrade.count }, 1 do
      Insights::TaskGrader::Backfill.run(limit: 1, live: true, io: io, pr_reader: NoLines.new)
    end
    assert TaskGrade.exists?(task_slug: "loop-live")
    assert_no_difference -> { TaskGrade.count } do
      Insights::TaskGrader::Backfill.run(limit: 1, live: true, io: StringIO.new, pr_reader: NoLines.new)
    end
  end
end
