require "test_helper"

class AviSizingJobTest < ActiveJob::TestCase
  # Stands in for Avi::Sizer.new(task): a plain size returns it; an Exception
  # value is raised (to exercise the job's ErrorLog rescue).
  StubSizer = Struct.new(:result) do
    def call
      raise result if result.is_a?(Exception)

      result
    end
  end

  def designed_unsized_task(session_id: nil, **attrs)
    devops = {}
    devops["session_id"] = session_id if session_id
    Task.create!(title: "Size me right now", stage: "designed", metadata: { "devops" => devops }, **attrs)
  end

  test "sets po_size from Avi's answer and records a task-scoped Activity when there's no session" do
    task = designed_unsized_task

    Avi::Sizer.stub(:new, ->(*) { StubSizer.new("large") }) do
      assert_difference -> { Activity.where(task_slug: task.slug, agent_slug: "avi").count }, 1 do
        AviSizingJob.perform_now(task.slug)
      end
    end

    assert_equal "large", task.reload.po_size
  end

  test "attributes the sizing as an agent=avi AtomicEvent on the creating session" do
    task = designed_unsized_task(session_id: "sess-abc123")

    Avi::Sizer.stub(:new, ->(*) { StubSizer.new("small") }) do
      assert_difference -> { AtomicEvent.where(session_id: "sess-abc123", agent: "avi").count }, 1 do
        AviSizingJob.perform_now(task.slug)
      end
    end

    assert_equal "small", task.reload.po_size
    event = AtomicEvent.where(session_id: "sess-abc123", agent: "avi").order(:id).last
    assert_equal task.slug, event.task_slug
    assert_equal "Plan", event.category
    assert event.closed?, "the sizing span must be self-contained (already closed)"
    assert_equal "sized small", event.outcome_slug
  end

  test "never clobbers an already-set po_size (idempotent)" do
    task = Task.create!(title: "Already sized here", stage: "designed", po_size: "small", metadata: { "devops" => {} })

    Avi::Sizer.stub(:new, ->(*) { StubSizer.new("xl") }) do
      AviSizingJob.perform_now(task.slug)
    end

    assert_equal "small", task.reload.po_size
  end

  test "leaves po_size blank and logs to ErrorLog when the LLM errors" do
    task = designed_unsized_task(session_id: "sess-err")

    Avi::Sizer.stub(:new, ->(*) { StubSizer.new(RuntimeError.new("LLM unavailable")) }) do
      assert_difference -> { ErrorLog.count }, 1 do
        AviSizingJob.perform_now(task.slug)
      end
    end

    assert_nil task.reload.po_size
  end

  test "leaves po_size blank without an ErrorLog when Avi returns nil" do
    task = designed_unsized_task

    Avi::Sizer.stub(:new, ->(*) { StubSizer.new(nil) }) do
      assert_no_difference -> { ErrorLog.count } do
        AviSizingJob.perform_now(task.slug)
      end
    end

    assert_nil task.reload.po_size
  end

  test "is a clean no-op for a missing task" do
    assert_nothing_raised do
      AviSizingJob.perform_now("task-does-not-exist")
    end
  end
end
