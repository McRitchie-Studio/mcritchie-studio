require "test_helper"
require_relative "../../bin/lib/agent_proposal_block"
require_relative "../support/proposal_block_fixtures"
require_relative "../support/note_block_fixtures"

# [unit] The worker's split of an answer into reply, notes and proposal
# (AgentMailbox::ProposalBlock), against the shared fixtures.
class AgentProposalBlockTest < ActiveSupport::TestCase
  ProposalBlockFixtures::CASES.each_with_index do |(text, reply, notes, proposal), i|
    define_method("test_proposal_case_#{i}") do
      got_reply, got_notes, got_proposal = AgentMailbox::ProposalBlock.split(text)
      assert_equal reply, got_reply, "reply for #{text.inspect}"
      assert_equal notes, got_notes, "notes for #{text.inspect}"
      proposal.nil? ? assert_nil(got_proposal, text) : assert_equal(proposal, got_proposal, "proposal for #{text.inspect}")
      refute_match(/proposal\s*=|"capability"/i, got_reply, "no part of the block is posted")
    end
  end

  # The notes fixtures still split the same through the combined split.
  NoteBlockFixtures::CASES.each_with_index do |(text, reply, facts), i|
    define_method("test_notes_case_#{i}_unchanged") do
      got_reply, got_notes, got_proposal = AgentMailbox::ProposalBlock.split(text)
      assert_equal [ reply, facts, nil ], [ got_reply, got_notes, got_proposal ]
    end
  end
end
