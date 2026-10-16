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
    @source = agent_message!(soul: "avi", person: @alex, author_ref: ALEX, status: "completed",
                             response_text: "Sure.", reply_external_id: "880001")
    @proposal = AgentProposal.create!(thread_key: @source.thread_key, channel: "discord", guild_id: GUILD,
                                      channel_ref: DESK, soul_slug: "avi", person: @alex, source_message: @source,
                                      kind: "ask", capability: "board_status", params: {}, summary: "Count",
                                      expires_at: 24.hours.from_now)
  end

  def reply(id, text, author:)
    raw = discord_raw(id, content: text, author: author, reply_to: "880001", guild: GUILD)
    AgentMessages::DiscordIngest.new(routes: agent_routes).call(raw, guild_id: GUILD, source: "discord-gateway")
  end

  test "the owner's go confirms and queues the run, never a model" do
    message = reply(3001, "go", author: ALEX)
    assert_equal [ "completed", "avi" ], [ message.status, message.soul_slug ]
    assert_equal "confirmed", @proposal.reload.status
    assert_equal message, @proposal.confirm_message
    assert_enqueued_with(job: AgentProposalJob, args: [ @proposal.id ])
    assert_nil AgentMessage.claimable(soul: "avi").first, "nothing waits for a model"
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
    assert_equal [ "received", "avi" ], [ message.status, message.soul_slug ]
    assert_equal "rejected", @proposal.reload.status
    bundle = AgentMessages::MemoryBundle.new(message).bundle
    assert_equal @proposal.id, bundle.dig("proposals", "last", "id")
  end

  test "a go with no open proposal in the thread is routed as usual" do
    @proposal.update!(status: "executed")
    other = agent_message!(soul: "avi", thread_key: @source.thread_key, status: "completed", response_text: "Hi.",
                           reply_external_id: "880009")
    raw = discord_raw(3007, content: "go", author: ALEX, reply_to: other.reply_external_id, guild: GUILD)
    message = AgentMessages::DiscordIngest.new(routes: agent_routes).call(raw, guild_id: GUILD, source: "discord-gateway")
    assert_equal "received", message.status
  end

  # Two proposals in one thread: the older was superseded when the newer landed.
  def newer_proposal!
    newer_source = agent_message!(soul: "avi", person: @alex, author_ref: ALEX, thread_key: @source.thread_key,
                                  status: "completed", response_text: "Also.", reply_external_id: "880002")
    @proposal.settle!("rejected", by: "board", result: { "reason" => "superseded" })
    AgentProposal.create!(thread_key: @source.thread_key, channel: "discord", guild_id: GUILD, channel_ref: DESK,
                          soul_slug: "avi", person: @alex, source_message: newer_source, kind: "ask",
                          capability: "recently_shipped", params: { "days" => 7 }, summary: "Shipped",
                          expires_at: 24.hours.from_now)
  end

  test "a go replying to a proposal's own message confirms THAT proposal" do
    newer = newer_proposal!
    raw = discord_raw(3010, content: "go", author: ALEX, reply_to: "880002", guild: GUILD)
    message = AgentMessages::DiscordIngest.new(routes: agent_routes).call(raw, guild_id: GUILD, source: "discord-gateway")
    assert_equal [ "confirmed", message ], [ newer.reload.status, newer.confirm_message ]
    assert_enqueued_with(job: AgentProposalJob, args: [ newer.id ])
  end

  test "a go replying to a superseded proposal never confirms the newer one" do
    newer = newer_proposal!
    message = reply(3011, "go", author: ALEX) # replies to 880001, the older proposal's post
    assert_equal AgentMessages::ProposalConfirm::CLOSED_TEXT, message.response_text
    assert message.events.exists?(kind: "proposal_closed")
    assert_equal "proposed", newer.reload.status, "the newer proposal is untouched"
    assert_equal "rejected", @proposal.reload.status
    assert_no_enqueued_jobs only: AgentProposalJob
  end

  test "a go on a proposal already confirmed says it is running, never that nothing ran" do
    first = reply(3020, "go", author: ALEX)
    assert_equal [ "confirmed", first ], [ @proposal.reload.status, @proposal.confirm_message ]

    again = reply(3021, "go", author: ALEX)
    assert_equal AgentMessages::ProposalConfirm::RUNNING_TEXT, again.response_text
    refute_match(/nothing ran/i, again.response_text)
    assert again.events.exists?(kind: "proposal_closed")
    assert_equal first, @proposal.reload.confirm_message, "the second go confirms nothing"

    @proposal.update!(status: "executed")
    ran = reply(3022, "go", author: ALEX)
    assert_equal AgentMessages::ProposalConfirm::RAN_TEXT, ran.response_text
  end

  test "a go replying to some other message in the thread confirms the newest pending one" do
    newer = newer_proposal!
    other = agent_message!(soul: "avi", thread_key: @source.thread_key, status: "completed", response_text: "Hm.",
                           reply_external_id: "880003")
    raw = discord_raw(3012, content: "go", author: ALEX, reply_to: other.reply_external_id, guild: GUILD)
    AgentMessages::DiscordIngest.new(routes: agent_routes).call(raw, guild_id: GUILD, source: "discord-gateway")
    assert_equal "confirmed", newer.reload.status
  end

  test "a go in another thread or at top level leaves the pending proposal alone" do
    elsewhere = agent_message!(soul: "avi", status: "completed", response_text: "Other thread.", reply_external_id: "880004")
    raw = discord_raw(3013, content: "go", author: ALEX, reply_to: "880004", guild: GUILD)
    in_other = AgentMessages::DiscordIngest.new(routes: agent_routes).call(raw, guild_id: GUILD, source: "discord-gateway")
    assert_equal elsewhere.thread_key, in_other.thread_key
    assert_equal "received", in_other.status, "routed as an ordinary message in its own thread"

    top = discord_raw(3014, content: "go", author: ALEX, guild: GUILD)
    assert_nil AgentMessages::DiscordIngest.new(routes: agent_routes).call(top, guild_id: GUILD, source: "discord-gateway"),
               "an unaddressed top-level go is not stored"
    assert_equal "proposed", @proposal.reload.status
    assert_no_enqueued_jobs only: AgentProposalJob
  end
end
