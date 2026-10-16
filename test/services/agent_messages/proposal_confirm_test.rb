require "test_helper"
require_relative "../../support/agent_message_fixtures"
require_relative "../../support/proposal_block_fixtures"

# [unit] Confirm by reply (AgentMessages::ProposalConfirm): the strict intent
# matcher, the owner-only rule (by role, never by id), and expiry, through the
# ingest the gateway and the poll share.
class ProposalConfirmTest < ActiveSupport::TestCase
  include AgentMessageFixtures
  include ActiveJob::TestHelper

  ALEX = "536552944271753216".freeze
  STRANGER = "777000000000000002".freeze

  test "intent is exactly go, no or change:, trimmed, any case, leading mentions ignored" do
    intent = AgentMessages::ProposalConfirm.method(:intent)
    assert_equal [ :go ], intent.call("go")
    assert_equal [ :go ], intent.call("  GO \n")
    assert_equal [ :go ], intent.call("<@123> go")
    assert_equal [ :no ], intent.call("No")
    assert_equal [ :change, "make it 3 days" ], intent.call("change: make it 3 days")
    assert_equal [ :change, "x" ], intent.call("CHANGE:x")
    [ "go ahead", "go!", "gogo", "no thanks", "change:", "change make it", "please go", "", nil ].each do |text|
      assert_nil intent.call(text), text.inspect
    end
  end

  setup do
    @alex = AgentPerson.resolve!(platform: "discord", external_id: ALEX, display_name: "Alex")
    @alex.set_role!("owner")
    @source = agent_message!(soul: "xan", person: @alex, author_ref: ALEX, status: "completed",
                             response_text: "Sure.", reply_external_id: "880001")
    @proposal = AgentProposal.create!(thread_key: @source.thread_key, channel: "discord", guild_id: GUILD,
                                      channel_ref: DESK, soul_slug: "xan", person: @alex, source_message: @source,
                                      kind: "ask", capability: "board_status", params: {}, summary: "Count",
                                      expires_at: 24.hours.from_now)
  end

  def reply(id, text, author:)
    raw = discord_raw(id, content: text, author: author, reply_to: "880001", guild: GUILD)
    AgentMessages::DiscordIngest.new(routes: agent_routes).call(raw, guild_id: GUILD, source: "discord-gateway")
  end

  test "the owner's go confirms and queues the run, never a model" do
    message = reply(3001, "go", author: ALEX)
    assert_equal [ "completed", "xan" ], [ message.status, message.soul_slug ]
    assert_equal "confirmed", @proposal.reload.status
    assert_equal message, @proposal.confirm_message
    assert_enqueued_with(job: AgentProposalJob, args: [ @proposal.id ])
    assert_nil AgentMessage.claimable(soul: "xan").first, "nothing waits for a model"
  end

  test "a go from anyone but the owner does nothing" do
    message = reply(3002, "go", author: STRANGER)
    assert_equal "held", message.status
    assert message.events.exists?(kind: "confirm_refused")
    assert_equal "proposed", @proposal.reload.status
    assert_no_enqueued_jobs only: [ AgentProposalJob, AgentMessageReplyJob ]
  end

  test "a team member's go does nothing either: confirming is the owner's alone" do
    AgentPerson.resolve!(platform: "discord", external_id: STRANGER, display_name: "Tam").set_role!("team")
    assert_equal "held", reply(3003, "go", author: STRANGER).status
    assert_equal "proposed", @proposal.reload.status
  end

  test "no drops it with a fixed reply" do
    message = reply(3004, "no", author: ALEX)
    assert_equal [ "completed", "queued", AgentMessages::ProposalConfirm::DROPPED_TEXT ],
                 [ message.status, message.reply_status, message.response_text ]
    assert_equal "rejected", @proposal.reload.status
    assert_enqueued_with(job: AgentMessageReplyJob, args: [ message.id ])
  end

  test "an expired proposal is not run; the reply says so" do
    @proposal.update!(expires_at: 1.minute.ago)
    message = reply(3005, "go", author: ALEX)
    assert_equal AgentMessages::ProposalConfirm::EXPIRED_TEXT, message.response_text
    assert_equal "expired", @proposal.reload.status
    assert_no_enqueued_jobs only: AgentProposalJob
  end

  test "change: goes to the soul with the prior proposal in its context" do
    message = reply(3006, "change: last 3 days", author: ALEX)
    assert_equal [ "received", "xan" ], [ message.status, message.soul_slug ]
    assert_equal "rejected", @proposal.reload.status
    bundle = AgentMessages::MemoryBundle.new(message).bundle
    assert_equal @proposal.id, bundle.dig("proposals", "last", "id")
  end

  test "a go with no open proposal in the thread is routed as usual" do
    @proposal.update!(status: "executed")
    message = reply(3007, "go", author: ALEX)
    assert_equal "received", message.status
  end
end
