require "test_helper"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [unit] The souls' read-only actions run under launchd, which has no Heroku
# login (measured 2026-10-15: `bin/release status` failed with
# HEROKU_NONINTERACTIVE_LOGIN). So every action reads the board through the agent
# API, and no Heroku credential reaches a child.
class AgentMailboxActionsTest < ActiveSupport::TestCase
  ACTIONS = AgentMailbox::Responder::ACTIONS

  test "avi's action is a board read through the agent API, not bin/release" do
    assert_equal %w[bin/task list], ACTIONS.fetch("avi")[:argv]
    refute ACTIONS.values.any? { |spec| spec[:argv].first == "bin/release" }, "no soul's action shells bin/release"
  end

  test "every action is a bin/task read" do
    ACTIONS.each do |soul, spec|
      assert_equal "bin/task", spec[:argv].first, "#{soul}'s action reads the board through bin/task"
      assert_includes %w[list show], spec[:argv][1], "#{soul}'s action is a read"
    end
  end

  test "no Heroku credential is on the child allow-list" do
    refute_includes AgentMailbox::CHILD_ENV_ALLOW, "HEROKU_API_KEY"
    refute(AgentMailbox::CHILD_ENV_ALLOW.any? { |name| name.start_with?("HEROKU") })
    env = AgentMailbox.child_env("HEROKU_API_KEY" => "k", "PATH" => "/bin", "TASK_API_BASE" => "http://x")
    assert_equal({ "PATH" => "/bin", "TASK_API_BASE" => "http://x" }, env)
  end
end
