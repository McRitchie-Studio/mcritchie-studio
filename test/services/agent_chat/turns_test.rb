require "test_helper"

# [unit] A row's status as the contract's turn status (AgentChat::Turns):
# held is its own word, because a held message is stored and an operator may
# still release it; failed means no answer is coming.
class AgentChatTurnsTest < ActiveSupport::TestCase
  def row(status, response_text: nil)
    AgentMessage.new(id: 1, status: status, response_text: response_text, content: "hi", created_at: Time.current, updated_at: Time.current)
  end

  test "each row status maps to its turn status" do
    assert_equal "pending", AgentChat::Turns.status_for(row("received"))
    assert_equal "typing", AgentChat::Turns.status_for(row("claimed"))
    assert_equal "answered", AgentChat::Turns.status_for(row("completed", response_text: "Sure."))
    assert_equal "held", AgentChat::Turns.status_for(row("held"))
    assert_equal "failed", AgentChat::Turns.status_for(row("completed"))
    assert_equal "failed", AgentChat::Turns.status_for(row("dead"))
    assert_equal "failed", AgentChat::Turns.status_for(row("unrouted"))
  end

  test "a held row is one user turn saying held, with no agent turn" do
    turns = AgentChat::Turns.for_row(row("held"))

    assert_equal [ %w[user held] ], turns.map { |t| t.values_at(:role, :status) }
  end
end
