require "test_helper"
require_relative "../../support/agent_message_fixtures"

# [unit] AgentProposals::Upgrade: Alex's upgrade proposal is filed only by Alex,
# only on his chat threads, only for a tier the packages sell; it is stored for
# the owner (never a catalog item, never settled by a word in the thread); and
# only the owner's approve changes a tier, and only on an app the person owns.
# [integration] AgentMessage#complete! cuts the block, stores the proposal,
# appends the line the visitor reads, and queues the Discord ping.
class AgentProposalsUpgradeTest < ActiveSupport::TestCase
  include AgentMessageFixtures
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "upgrade-visitor@example.com", name: "Up Grade")
    @person = AgentPerson.resolve!(platform: "web", external_id: "upgrade-visitor-#{SecureRandom.hex(3)}", display_name: "Up Grade")
    @app = App.create!(slug: "upgrade-test-app", name: "Upgrade Test App", package_tier: "builder")
    AppMembership.create!(app_slug: @app.slug, user_slug: @user.slug)
  end

  def chat_message!(soul: "alex", thread_key: AgentChat.user_thread_key("alex", @user.id))
    agent_message!(soul: soul, person: @person, channel: "web", guild_id: nil, channel_ref: AgentChat::CHANNEL_REF,
                   thread_key: thread_key, author_ref: @person.id.to_s,
                   status: "claimed", claimed_by: "w1", lease_expires_at: 5.minutes.from_now, attempts: 1)
  end

  def block(params = { "tier" => "pro", "billing" => "annual", "app" => @app.slug }, summary: "Up wants Pro for their app")
    { "kind" => "upgrade", "params" => params, "summary" => summary }
  end

  # CONTROL: send the block to AgentProposal.record_from! instead (drop the
  # Upgrade branch in complete!) and every assert after the first fails: the
  # catalog refuses an unknown kind and nothing is stored.
  test "[integration] complete! stores Alex's upgrade proposal, tells the visitor, and queues the ping" do
    message = chat_message!
    assert_enqueued_with(job: UpgradeProposalNoticeJob) do
      message.complete!(worker: "w1", response_text: "I'll send that to Alex McRitchie.\n===PROPOSAL===\n#{block.to_json}")
    end

    proposal = AgentProposal.sole
    assert_equal [ "upgrade", "tier", "proposed", "alex", message.thread_key, @person.id ],
                 [ proposal.kind, proposal.capability, proposal.status, proposal.soul_slug, proposal.thread_key, proposal.person_id ]
    assert_equal({ "tier" => "pro", "billing" => "annual", "app" => @app.slug }, proposal.params)
    assert_in_delta 14.days.from_now, proposal.expires_at, 5
    posted = message.reload.response_text
    assert posted.start_with?("I'll send that to Alex McRitchie.")
    refute_includes posted, "PROPOSAL"
    assert_includes posted, "Sent to Alex McRitchie: a request to move you to Pro (annual). Nothing changes and nobody is charged until he approves it."
    refute_includes posted, AgentProposal::CONFIRM_LINE, "the visitor is never told to reply go"
    assert_equal "builder", @app.reload.package_tier, "filing changes nothing"
  end

  test "an upgrade block is refused off Alex's chat threads, from another soul, and with bad params" do
    {
      "another soul" => [ chat_message!(soul: "avi"), block ],
      "a Discord thread" => [ agent_message!(soul: "alex", person: @person, status: "claimed", claimed_by: "w1",
                                             lease_expires_at: 5.minutes.from_now, attempts: 1), block ],
      "the free tier" => [ chat_message!, block({ "tier" => "vibe" }) ],
      "an unknown tier" => [ chat_message!, block({ "tier" => "platinum" }) ],
      "a bad billing" => [ chat_message!, block({ "tier" => "pro", "billing" => "weekly" }) ],
      "an unknown param" => [ chat_message!, block({ "tier" => "pro", "price" => "1" }) ],
      "a bad app slug" => [ chat_message!, block({ "tier" => "pro", "app" => "../etc" }) ]
    }.each do |label, (message, raw)|
      message.complete!(worker: "w1", response_text: "Sure.", proposal: raw)
      assert_equal "Sure.", message.reload.response_text, label
      assert message.events.exists?(kind: "proposal_refused"), label
    end
    assert_equal 0, AgentProposal.count
  end

  test "billing defaults to monthly and a newer proposal supersedes the open one" do
    first = chat_message!
    first.complete!(worker: "w1", response_text: "Sure.", proposal: block({ "tier" => "builder" }))
    second = chat_message!
    second.complete!(worker: "w1", response_text: "Sure.", proposal: block({ "tier" => "team" }))

    older, newer = AgentProposal.order(:id).to_a
    assert_equal "monthly", older.params["billing"]
    assert_equal [ "rejected", "superseded" ], [ older.status, older.result["reason"] ]
    assert_equal "proposed", newer.status
  end

  test "no word in the thread settles an upgrade" do
    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    proposal = AgentProposal.sole
    scope = { thread_key: proposal.thread_key, channel: proposal.channel, guild_id: proposal.guild_id, channel_ref: proposal.channel_ref }
    assert_nil AgentProposal.for_word(**scope)
    assert_nil AgentProposal.latest_pending(**scope)
    assert_raises(AgentProposals::Executor::NotEnabled) { AgentProposals::Executor.new(proposal).run }
  end

  # CONTROL: drop the AppMembership check in owned_app and the "not theirs"
  # assert fails: an approval would move someone else's app.
  test "the owner's approve sets the tier only on an app the person owns" do
    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    proposal = AgentProposal.sole
    AgentProposals::Upgrade.approve!(proposal, by: "user:owner")
    assert_equal "pro", @app.reload.package_tier
    assert_equal [ "executed", true, "builder", "user:owner" ],
                 [ proposal.reload.status, proposal.result["applied"], proposal.result["from"], proposal.settled_by ]
    assert proposal.source_message.events.exists?(kind: "proposal_executed")

    other = App.create!(slug: "someone-elses-app", name: "Someone Else", package_tier: "builder")
    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block({ "tier" => "team", "app" => other.slug }))
    theirs_not = AgentProposal.order(:id).last
    AgentProposals::Upgrade.approve!(theirs_not, by: "user:owner")
    assert_equal "builder", other.reload.package_tier, "not theirs: the yes is recorded, the tier is not set"
    assert_equal false, theirs_not.reload.result["applied"]
  end

  test "a visitor's approval is recorded for a follow-up; decline and a closed proposal change nothing" do
    visitor = chat_message!(thread_key: AgentChat.anon_thread_key("alex", "d" * 32))
    visitor.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    proposal = AgentProposal.sole
    assert_nil AgentProposals::Upgrade.user_for(proposal)
    AgentProposals::Upgrade.approve!(proposal, by: "user:owner")
    assert_equal [ "executed", false ], [ proposal.reload.status, proposal.result["applied"] ]
    assert_equal "builder", @app.reload.package_tier

    assert_raises(AgentProposals::Upgrade::Closed) { AgentProposals::Upgrade.decline!(proposal, by: "user:owner") }

    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    open = AgentProposal.order(:id).last
    AgentProposals::Upgrade.decline!(open, by: "user:owner")
    assert_equal "rejected", open.reload.status
    assert_raises(AgentProposals::Upgrade::Closed) { AgentProposals::Upgrade.approve!(open, by: "user:owner") }
    assert_equal "builder", @app.reload.package_tier
  end

  test "the Discord ping names the tier and the review page, never the person's email" do
    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    embed = UpgradeProposalNoticeJob.embed(AgentProposal.sole)
    assert_equal "Alex proposes an upgrade to Pro", embed[:title]
    assert(embed[:fields].any? { |f| f[:value].end_with?("/admin/upgrade_proposals") })
    refute_includes embed.to_s, @user.email
  end

  # ---- the visitor hears the owner's answer (Carl's review of #2422) -------------

  def outcome_rows(proposal) = AgentMessage.where(channel: "web", thread_key: proposal.thread_key, external_id: "upgrade-proposal:#{proposal.id}:#{proposal.status}")

  # CONTROL: drop post_outcome! from approve! and the first assert fails: the
  # visitor's thread never hears the owner said yes.
  test "[unit] an approval posts Alex's word in the thread: an agent turn only, counted against no cap, once" do
    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    proposal = AgentProposal.sole
    AgentProposals::Upgrade.approve!(proposal, by: "user:owner")

    row = outcome_rows(proposal.reload).sole
    assert_equal [ "completed", "alex", proposal.person_id, true ], [ row.status, row.soul_slug, row.person_id, row.run_meta["code_written"] ]
    assert_includes row.response_text, "Good news: Alex McRitchie approved your move to Pro (annual), and #{@app.slug} is on Pro now."
    turns = AgentChat::Turns.for([ row ])
    assert_equal [ [ "agent", "answered" ] ], turns.map { |t| [ t[:role], t[:status] ] }, "no visitor bubble for words nobody typed"
    assert_equal row.response_text, turns.first[:text]
    refute AgentChat::Turns.pending?(proposal.thread_key), "no dispatcher answer is coming for it"

    assert_equal row, AgentProposals::Upgrade.post_outcome!(proposal), "idempotent: one row per proposal and outcome"
    assert_equal 1, outcome_rows(proposal).count
    visitor_rows = AgentChat::Caps.new(policy: nil).send(:on_thread, proposal.thread_key)
    refute_includes visitor_rows, row, "Alex's word is not the visitor's turn"
  end

  test "[unit] a visitor's approval and a decline each get their own words" do
    chat_message!(thread_key: AgentChat.anon_thread_key("alex", "e" * 32)).complete!(worker: "w1", response_text: "Sure.", proposal: block)
    visitor = AgentProposal.sole
    AgentProposals::Upgrade.approve!(visitor, by: "user:owner")
    assert_includes outcome_rows(visitor.reload).sole.response_text,
                    "approved your request to move to Pro (annual). He'll be in touch to set it up with you; nothing changes"

    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block({ "tier" => "team" }))
    declined = AgentProposal.order(:id).last
    AgentProposals::Upgrade.decline!(declined, by: "user:owner")
    text = outcome_rows(declined.reload).sole.response_text
    assert_includes text, "isn't approving it right now. Nothing has changed on your account."
    assert_match %r{I'm happy to talk through the options with you here, or you can book a call with him: https://\S+/schedule\z}, text
    refute_match(/\A>|\*\*/, text, "plain text, no Markdown")
  end

  test "[unit] a failed word is an ErrorLog row, and the decision stands" do
    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    proposal = AgentProposal.sole
    AgentMessage.stub(:create!, ->(*) { raise ActiveRecord::RecordInvalid }) do
      assert_difference -> { ErrorLog.count }, 1 do
        AgentProposals::Upgrade.approve!(proposal, by: "user:owner")
      end
    end
    assert_equal "executed", proposal.reload.status
    assert_equal "pro", @app.reload.package_tier
    assert_match(/upgrade proposal #{proposal.id} outcome/, ErrorLog.order(:id).last.target_name)
  end

  # CONTROL: return nil from open_json and every assert but the last fails.
  test "[unit] open_json gives the next answer the thread's newest proposal and where it stands" do
    first = chat_message!
    first.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    proposal = AgentProposal.sole
    later = -> { chat_message!.tap { |m| m.update_columns(created_at: 1.second.from_now) } }

    assert_equal({ "tier" => "pro", "billing" => "annual", "app" => @app.slug, "state" => "waiting" }, AgentProposals::Upgrade.open_json(later.call))
    assert_equal "expired", AgentProposals::Upgrade.open_json(later.call.tap { |m| m.update_columns(created_at: 15.days.from_now) })["state"]
    AgentProposals::Upgrade.decline!(proposal, by: "user:owner")
    assert_equal "declined", AgentProposals::Upgrade.open_json(later.call)["state"]
    proposal.update_columns(status: "executed")
    assert_equal "approved", AgentProposals::Upgrade.open_json(later.call)["state"]
    assert_nil AgentProposals::Upgrade.open_json(chat_message!(thread_key: AgentChat.anon_thread_key("alex", "f" * 32)))
  end

  test "[integration] the bundle carries it as packages.upgrade.open on Alex's chat" do
    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    message = chat_message!
    message.update_columns(created_at: 1.second.from_now)
    assert_equal "waiting", AgentMessages::MemoryBundle.new(message).bundle.dig("packages", "upgrade", "open", "state")
  end

  # CONTROL: restore the Rails.logger.warn rescue and the ErrorLog count does not move.
  test "[unit] a failed Discord ping is an ErrorLog row, not only a log line" do
    chat_message!.complete!(worker: "w1", response_text: "Sure.", proposal: block)
    proposal = AgentProposal.sole
    home = Struct.new(:medium, :webhook_url, :label) { def channel? = true }.new("discord", "https://discord.example/hook", "test home")
    UpgradeProposalNoticeJob.stub(:home, home) do
      Media.stub(:post, ->(*, **) { raise Media::Error, "discord said 500" }) do
        assert_difference -> { ErrorLog.count }, 1 do
          UpgradeProposalNoticeJob.perform_now(proposal.id)
        end
      end
    end
    log = ErrorLog.order(:id).last
    assert_equal "discord said 500", log.message
    assert_equal "upgrade proposal #{proposal.id} Discord notice", log.target_name
  end
end
