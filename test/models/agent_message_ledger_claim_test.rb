require "test_helper"
require_relative "../support/agent_message_fixtures"

# [unit] Claims serialize per ledger (person + channel + soul) as well as per
# thread, so a person's second message is answered only after their first, with
# the first exchange in its context (AgentMessages::ThreadLedger).
class AgentMessageLedgerClaimTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  test "a person's second message waits for their first; another person's does not" do
    first = agent_message!(soul: "xan", author_ref: "500", content: "one")
    second = agent_message!(soul: "xan", author_ref: "500", content: "two")
    bea = agent_message!(soul: "xan", author_ref: "501", content: "bea")

    assert_equal first, AgentMessage.claim!(soul: "xan", worker: "w1").message
    assert_equal bea, AgentMessage.claim!(soul: "xan", worker: "w2").message, "a different ledger is not held back"
    assert_nil AgentMessage.claim!(soul: "xan", worker: "w3").message, "the same person's second waits"

    first.reload.complete!(worker: "w1", response_text: "done")
    assert_equal second, AgentMessage.claim!(soul: "xan", worker: "w3").message
  end

  test "the hold is per soul and per channel, and rows with no author id are not held" do
    agent_message!(soul: "xan", author_ref: "500")
    to_avi = agent_message!(soul: "avi", author_ref: "500")
    elsewhere = agent_message!(soul: "xan", author_ref: "500", channel_ref: QUIET)
    agent_message!(soul: "xan", author_ref: "")
    anon = agent_message!(soul: "xan", author_ref: "")

    claimable = AgentMessage.claimable(soul: %w[xan avi]).to_a
    assert_includes claimable, to_avi
    assert_includes claimable, elsewhere
    assert_includes claimable, anon
  end
end
