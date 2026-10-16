require "test_helper"
require_relative "../support/agent_message_fixtures"
require_relative "../support/proposal_block_fixtures"

# [unit] The board's side of a proposal: complete! cuts the PROPOSAL block with
# the worker's pattern, validates it against the registry and the sender's
# role, stores it with the confirm line, and logs (never shows) a refused one.
class AgentProposalTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  setup do
    @owner = AgentPerson.resolve!(platform: "discord", external_id: "536552944271753216", display_name: "Alex")
    @owner.set_role!("owner")
    @stranger = AgentPerson.resolve!(platform: "discord", external_id: "777000000000000001", display_name: "Bea")
  end

  def claimed!(soul: "avi", person: @owner)
    agent_message!(soul: soul, person: person, author_ref: person.identities.first.external_id,
                   status: "claimed", claimed_by: "w1", lease_expires_at: 5.minutes.from_now, attempts: 1)
  end

  ProposalBlockFixtures::CASES.each_with_index do |(text, reply, _notes, proposal), i|
    test "the board never posts the block (fixture #{i})" do
      message = claimed!
      message.complete!(worker: "w1", response_text: text)
      posted = message.reload.response_text
      assert posted.start_with?(reply), "posted #{posted.inspect}"
      refute_match(/"capability"/, posted)
      if proposal
        assert_includes posted, AgentProposal::CONFIRM_LINE
        assert_equal 1, AgentProposal.where(source_message: message).count
      else
        assert_equal reply, posted
      end
    end
  end

  test "an accepted proposal is stored with its thread, person and a 24-hour expiry" do
    message = claimed!
    message.complete!(worker: "w1", response_text: "Sure.", proposal: ProposalBlockFixtures::ASK)
    proposal = AgentProposal.sole
    assert_equal [ message.thread_key, "avi", @owner.id, "ask", "board_status", "proposed" ],
                 [ proposal.thread_key, proposal.soul_slug, proposal.person_id, proposal.kind, proposal.capability, proposal.status ]
    assert_in_delta 24.hours.from_now, proposal.expires_at, 5
    assert_equal "Sure.\n\n> Proposed: Count the board\n> Runs: ask `board_status` (no params)\n#{AgentProposal::CONFIRM_LINE}",
                 message.reload.response_text
    assert message.events.exists?(kind: "proposed")
  end

  test "the posted line shows the capability and params the board checked, not only the model's summary" do
    message = claimed!
    message.complete!(worker: "w1", response_text: "Sure.",
                      proposal: { "kind" => "ask", "capability" => "recently_shipped", "params" => { "days" => "3" },
                                  "summary" => "Everything, forever" })
    assert_includes message.reload.response_text, "> Runs: ask `recently_shipped` · days 3\n"

    change = AgentProposal.new(kind: "change", capability: "task", summary: "s",
                               params: { "title" => "Footer `Toggle`", "accept" => [ "Toggles\nlight", "B" ] })
    assert_equal "change `task` · title Footer Toggle · accept Toggles light; B", change.runs_line,
                 "lists join with ;, and backticks and newlines cannot break the line"
    long = AgentProposal.new(kind: "change", capability: "task", params: { "accept" => [ "x" * 500 ] * 6 })
    assert_operator long.runs_line.length, :<=, AgentProposal::RUNS_LINE_LIMIT
  end

  test "a refused proposal is logged and never shown" do
    {
      "unknown capability" => { "kind" => "ask", "capability" => "drop_tables" },
      "another domain's capability" => { "kind" => "ask", "capability" => "signups_and_errors" }
    }.each do |label, raw|
      message = claimed!
      message.complete!(worker: "w1", response_text: "Sure.", proposal: raw)
      assert_equal "Sure.", message.reload.response_text, label
      assert message.events.exists?(kind: "proposal_refused"), label
    end
    message = claimed!(person: @stranger)
    message.complete!(worker: "w1", response_text: "Sure.", proposal: ProposalBlockFixtures::ASK)
    assert_equal "Sure.", message.reload.response_text, "a public sender may not request board_status"
    assert_match(/public may not request/, message.events.find_by(kind: "proposal_refused").detail["reason"])
    assert_equal 0, AgentProposal.count
  end

  test "a newer proposal in the thread rejects the older one" do
    first = claimed!
    first.complete!(worker: "w1", response_text: "A.", proposal: ProposalBlockFixtures::ASK)
    second = claimed!(soul: "avi").tap { |m| m.update!(thread_key: first.thread_key) }
    second.complete!(worker: "w1", response_text: "B.", proposal: ProposalBlockFixtures::ASK)
    assert_equal %w[rejected proposed], AgentProposal.order(:id).pluck(:status)
  end

  test "expiry is 24 hours" do
    message = claimed!
    message.complete!(worker: "w1", response_text: "Sure.", proposal: ProposalBlockFixtures::ASK)
    proposal = AgentProposal.sole
    refute proposal.expired?(23.hours.from_now)
    assert proposal.expired?(25.hours.from_now)
  end

  test "the status CHECK holds exactly AgentProposal::STATUSES" do
    definition = ActiveRecord::Base.connection.select_value(<<~SQL.squish)
      SELECT pg_get_constraintdef(oid) FROM pg_constraint WHERE conname = 'agent_proposals_status_known'
    SQL
    assert_equal AgentProposal::STATUSES.sort, definition.scan(/'([a-z_]+)'/).flatten.sort
  end
end
