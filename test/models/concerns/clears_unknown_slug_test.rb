require "test_helper"

# [unit] The writers whose callers pass whatever handle they hold keep writing
# under the slug foreign keys: a handle no row holds is cased, kept, or cleared,
# never raised. Task, a record rather than a log, refuses it with the reason.
class ClearsUnknownSlugTest < ActiveSupport::TestCase
  test "[unit] a note from a mascot keeps the handle in metadata and clears the key" do
    note = Activity.create!(activity_type: "comment", description: "from a mascot", agent_slug: "charmander",
                            task_slug: "live-score-watch")

    assert_nil note.agent_slug
    assert_nil note.task_slug
    assert_equal({ "agent_handle" => "charmander", "task_handle" => "live-score-watch" },
                 note.metadata.slice("agent_handle", "task_handle"))
  end

  test "[unit] a handle that differs from an agent only by case takes the agent" do
    note = Activity.create!(activity_type: "comment", description: "cased", agent_slug: "Xan")

    assert_equal "xan", note.agent_slug
    assert_nil note.metadata["agent_handle"]
  end

  test "[unit] a capture naming no task still lands, with the task cleared" do
    action = AgentAction.capture(session_id: "clears-unknown", kind: "tool", summary: "probe", task_slug: "live-score-watch")

    assert action&.persisted?
    assert_nil action.task_slug
  end

  test "[unit] an activity naming no task opens, with the task cleared" do
    activity = AgentActivity.open_activity!(session_id: "clears-unknown", category: "Explore", reason_slug: "probe",
                                            task_slug: "not-a-task-yet")

    assert activity.persisted?
    assert_nil activity.task_slug
  end

  test "[unit] a desk record maps a sibling app slug and clears an unknown one" do
    sibling = DeskRecord.create!(worktree_path: "/tmp/clears-sibling", status: "live",
                                 app_slug: "#{apps(:mcritchie_studio).slug}.sibling", task_slug: "local-only-task")
    stranger = DeskRecord.create!(worktree_path: "/tmp/clears-stranger", status: "live", app_slug: "not-an-app")

    assert_equal apps(:mcritchie_studio).slug, sibling.app_slug
    assert_nil sibling.task_slug
    assert_nil stranger.app_slug
  end

  test "[unit] a task naming no agent is refused with the reason" do
    task = tasks(:new_task)
    task.agent_slug = "charmander"

    assert_not task.valid?
    assert_includes task.errors[:agent_slug], "names no agent (charmander)"
  end
end
