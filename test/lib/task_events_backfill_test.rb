require "test_helper"
require "rake"
require "minitest/mock"
require "tmpdir"
require "fileutils"
require "json"
require_relative "../../lib/agent_session_usage"

# Coverage for lib/tasks/task_events.rake — the acceptance criterion (synthesize
# a TaskEvent timeline for legacy tasks from their stage-timestamp columns) that
# shipped without a test. Runs the task in-process against the test DB, inside
# the fixture transaction, so it rolls back cleanly.
class TaskEventsBackfillTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("task_events:backfill")
  end

  # reenable so the same process can invoke it more than once (idempotency check).
  def run_backfill
    task = Rake::Task["task_events:backfill"]
    task.reenable
    capture_io { task.invoke } # swallow the summary puts
  end

  # [integration] a legacy task with no events gets a system, backfilled, usage-
  # free timeline reconstructed from its stage timestamps.
  test "backfill synthesizes a system event timeline from the stage timestamps" do
    t0 = 3.days.ago.change(usec: 0)
    task = Task.create!(title: "backfill timestamp task", stage: "shipped")
    # Stamp a known historical timeline, then strip the genesis event so the row
    # looks like pre-TaskEvent legacy data the backfill is meant to reconstruct.
    task.update_columns(
      created_at: t0,
      started_at: t0 + 1.hour,
      submitted_at: t0 + 2.hours,
      reviewed_at: t0 + 3.hours,
      assembled_at: t0 + 4.hours,
      completed_at: t0 + 5.hours
    )
    task.task_events.delete_all

    run_backfill

    events = task.task_events.chronological.to_a
    assert_equal 6, events.size
    assert_equal [nil, "designed", "building", "submitted", "reviewed", "assembled"], events.map(&:from_stage)
    assert_equal %w[designed building submitted reviewed assembled shipped], events.map(&:to_stage)
    assert(events.all? { |e| e.source == "system" }, "every synthesized row is source=system")
    assert(events.all?(&:backfilled?), "every synthesized row is flagged backfilled=true")
    assert(events.none?(&:usage?), "synthesized rows carry no usage attribution")
    assert(events.all? { |e| e.actor.nil? }, "synthesized rows carry no actor")
    assert_equal 3600, events[1].seconds_in_from # the gap between the first two points
  end

  # [integration] a task that already has events is skipped — re-running the
  # backfill is a no-op for it.
  test "backfill is idempotent for tasks that already have events" do
    task = Task.create!(title: "backfill idempotent task", stage: "building")
    assert_operator task.task_events.count, :>=, 1, "create! writes a genesis event"

    assert_no_difference -> { task.task_events.count } do
      run_backfill
    end
    assert_no_difference -> { task.task_events.count } do
      run_backfill # a second pass still adds nothing
    end
  end

  # --- backfill_usage: best-effort historical MODEL recovery ----------------

  SID = "1f1f1f1f-2e2e-3d3d-4c4c-5b5b5b5b5b5b"

  def run_backfill_usage
    task = Rake::Task["task_events:backfill_usage"]
    task.reenable
    capture_io { task.invoke }
  end

  # Stub AgentSessionUsage.default_root at a tmp dir holding one session
  # transcript, so the rake finds it without touching the real ~/.claude.
  def with_transcript_root(session, lines)
    Dir.mktmpdir do |root|
      proj = File.join(root, "proj")
      FileUtils.mkdir_p(proj)
      File.write(File.join(proj, "#{session}.jsonl"), "#{lines.join("\n")}\n")
      AgentSessionUsage.stub(:default_root, root) { yield }
    end
  end

  def assistant_line(model: "claude-opus-4-8", input: 10, output: 5)
    JSON.generate("type" => "assistant", "message" => {
      "model" => model,
      "usage" => { "input_tokens" => input, "output_tokens" => output,
                   "cache_creation_input_tokens" => 0, "cache_read_input_tokens" => 0 }
    })
  end

  # [integration] a usage-free transition whose task records a build session gets
  # its MODEL recovered + flagged — but tokens/cost are left nil (unrecoverable).
  test "backfill_usage fills the model only, never fabricating tokens or cost" do
    task = Task.create!(title: "usage backfill task", stage: "building",
                        metadata: { "devops" => { "session_id" => SID } })
    event = task.task_events.transitions.first
    assert_nil event.model

    with_transcript_root(SID, [assistant_line]) { run_backfill_usage }

    event.reload
    assert_equal "claude-opus-4-8", event.model
    assert event.metadata["usage_backfilled"], "the row is flagged as an approximate backfill"
    assert_nil event.tokens_in, "token deltas are NOT recoverable for history — never fabricated"
    assert_nil event.cost
  end

  # [integration] a row that already carries usage is never clobbered.
  test "backfill_usage never overwrites an event that already has usage" do
    task = Task.create!(title: "already has usage task", stage: "building",
                        metadata: { "devops" => { "session_id" => SID } })
    event = task.task_events.transitions.first
    event.update!(model: "claude-sonnet-4-6", tokens_in: 99)

    with_transcript_root(SID, [assistant_line]) { run_backfill_usage }

    assert_equal "claude-sonnet-4-6", event.reload.model, "a real captured value wins"
    assert_equal 99, event.tokens_in
  end

  # [integration] no transcript → the row is left spine-only (nothing fabricated).
  test "backfill_usage skips cleanly when no transcript can be found" do
    task = Task.create!(title: "no transcript task", stage: "building",
                        metadata: { "devops" => { "session_id" => "no-such-session-99999" } })
    event = task.task_events.transitions.first

    Dir.mktmpdir { |root| AgentSessionUsage.stub(:default_root, root) { run_backfill_usage } }

    assert_nil event.reload.model, "no transcript → left as a spine-only row"
  end
end
