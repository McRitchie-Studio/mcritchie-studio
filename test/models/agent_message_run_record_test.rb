require "test_helper"
require_relative "../support/agent_message_fixtures"

# [unit] What complete! keeps of a worker's run report (AgentMessage.run_record)
# and the resume line built from it.
class AgentMessageRunRecordTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  test "each field is capped, run_meta keeps only known scalar keys" do
    record = AgentMessage.run_record(
      "claude_session_id" => "s" * 500, "claude_cwd" => " /x ", "reasoning" => "r" * 50_000,
      "run_meta" => { "thinking_tokens" => 7, "model" => "m" * 500, "evil" => "x", "num_turns" => { "a" => 1 } }
    )
    assert_equal 100, record[:claude_session_id].length
    assert_equal "/x", record[:claude_cwd]
    assert_equal 20_000, record[:reasoning].length
    assert_equal({ "thinking_tokens" => 7, "model" => "m" * 200 }, record[:run_meta])
    assert_equal({ claude_session_id: nil, claude_cwd: nil, reasoning: nil, run_meta: {} }, AgentMessage.run_record(nil))
  end

  test "complete! stores the run, and the resume line quotes the folder and refuses an odd session id" do
    message = agent_message!(soul: "xan")
    AgentMessage.claim!(soul: "xan", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "hi",
                             run: { claude_session_id: "abc-123", claude_cwd: "/Users/a b/.agents/mailbox/xan" })

    assert_equal "cd /Users/a\\ b/.agents/mailbox/xan && claude --resume abc-123", message.reload.resume_command
    message.update_columns(claude_session_id: "x; rm -rf /")
    assert_nil message.resume_command
    message.update_columns(claude_session_id: "abc", claude_cwd: nil)
    assert_equal "cd ~/.agents/mailbox/xan && claude --resume abc", message.resume_command
  end
end
