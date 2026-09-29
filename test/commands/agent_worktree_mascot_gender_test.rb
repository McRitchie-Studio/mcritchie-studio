require "test_helper"
require "json"
require_relative "../support/agent_worktree_fixture"

# [integration] tasks/show-mascot-gender-symbol: the desk context carries every
# mascot's DISPLAY gender, which bin/statusline turns into the name's sign. Its own
# file, per the append-hotspot ceiling on agent_worktree_test.rb.
class AgentWorktreeMascotGenderTest < ActiveSupport::TestCase
  include AgentWorktreeFixture

  # tasks/show-mascot-gender-symbol: every mascot's display gender rides the desk
  # context (bin/statusline signs the name by it), not just the Nidoran family's —
  # "genderless" included, so Magnemite renders Magnemite⚥.
  test "context regeneration keeps any mascot's display gender, genderless included" do
    agent_worktree!("bind-task", "mcritchie-studio", @task, "task-mascot-gender")

    ctx_path = File.join(@worktree_dir, ".agent-context.json")
    context = JSON.parse(File.read(ctx_path))
    context["mascot"] = "magnemite"
    context["mascot_gender"] = "genderless"
    File.write(ctx_path, "#{JSON.pretty_generate(context)}\n")

    agent_worktree!("whereami", "mcritchie-studio", @task)

    assert_equal "genderless", JSON.parse(File.read(ctx_path))["mascot_gender"]
  end
end
