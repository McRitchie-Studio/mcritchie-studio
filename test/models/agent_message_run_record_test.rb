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

  test "a numeric run key keeps only a finite, non-negative number; audience is the board's stamp" do
    record = AgentMessage.run_record(
      "run_meta" => { "input_tokens" => "999999", "output_tokens" => -5, "total_cost_usd" => 0.02,
                      "cache_read_tokens" => Float::INFINITY, "audience" => "owner" }
    )
    assert_equal({ "total_cost_usd" => 0.02 }, record[:run_meta])

    person = AgentPerson.create!(display_name: "C", role: "client", client_domain: "turf_monster")
    message = agent_message!(soul: "ray", person: person)
    AgentMessage.claim!(soul: "ray", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "hi", run: { run_meta: { "audience" => "owner", "output_tokens" => 3 } })
    assert_equal({ "output_tokens" => 3, "audience" => "client" }, message.reload.run_meta)
  end

  test "complete! stores the run, and the resume line quotes the folder and refuses an odd session id" do
    message = agent_message!(soul: "ray")
    AgentMessage.claim!(soul: "ray", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "hi",
                             run: { claude_session_id: "abc-123", claude_cwd: "/Users/a b/.agents/mailbox/ray" })

    assert_equal "cd /Users/a\\ b/.agents/mailbox/ray && claude --resume abc-123", message.reload.resume_command
    message.update_columns(claude_session_id: "x; rm -rf /")
    assert_nil message.resume_command
    message.update_columns(claude_session_id: "abc", claude_cwd: nil)
    assert_equal "cd ~/.agents/mailbox/ray && claude --resume abc", message.resume_command
  end
end
