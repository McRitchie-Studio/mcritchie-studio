require "test_helper"
require_relative "../support/agent_message_fixtures"

# [integration] Operate on go, in Slack (docs/agents/system/agent-message-loop.md,
# "Operations"): Turf's operate proposal in a Slack thread runs ONLY on the
# owner's `go` reply in that thread, runs exactly the params stored at propose
# time, runs once on a double go, records who confirmed, and reports a failure
# in the thread. Turf Monster's operator endpoint is a stubbed transport.
class SlackOperateOnGoTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AgentMessageFixtures

  TEAM = "T0CC9DQ9NAK".freeze      # the shipped slack.team_id
  CHAN = "C0CD8ETBZBM".freeze
  OWNER = "U0CCSMUMQJV".freeze     # Alex McRitchie (slack.owner_user_id)
  APP_BOT = "U0CE93ACBA4".freeze
  STRANGER = "U0STRANGE1".freeze
  ROOT = "1761900000.000100".freeze

  class Transport
    attr_reader :calls

    def initialize(*answers)
      @answers = answers
      @calls = []
    end

    def call(verb, uri, body, _headers)
      @calls << { verb: verb, path: uri.path, body: body && JSON.parse(body) }
      code, payload = @answers.shift || [ 500, {} ]
      [ code, JSON.generate(payload) ]
    end
  end

  setup do
    AgentMessages::SlackRoutes.reset!
    @owner = AgentPerson.seed_owner!
    @transport = Transport.new(
      [ 200, { "state" => "queued", "slug" => "nfl-2026-weeks-8-10", "name" => "NFL Weeks 8-10", "entries" => 0,
               "paid_entries" => 0, "pending_transaction_id" => 9, "treasury_path" => "/admin/pending_transactions" } ]
    )
    AgentProposals::Executor.operator = AgentProposals::TurfOperator.new(
      env: { AgentProposals::TurfOperator::TOKEN_ENV => "t" }, base_url: "https://turf.example", transport: @transport
    )
    @answer = AgentMessage.create!(channel: "slack", external_id: "#{CHAN}:#{ROOT}", guild_id: TEAM, channel_ref: CHAN,
                                   thread_key: "slack:#{CHAN}:#{ROOT}", author_ref: OWNER, author_name: "Alex",
                                   person: @owner, content: "Turf, cancel weeks 8-10", soul_slug: "turf_monster",
                                   routed_by: "name", status: "completed")
    @proposal = AgentProposal.create!(thread_key: @answer.thread_key, channel: "slack", guild_id: TEAM, channel_ref: CHAN,
                                      soul_slug: "turf_monster", person: @owner, source_message: @answer, kind: "operate",
                                      capability: "cancel_contest",
                                      params: { "contest" => "nfl-2026-weeks-8-10", "paid_entries" => "none" },
                                      summary: "Cancel NFL Weeks 8-10", expires_at: 1.day.from_now)
  end

  teardown do
    AgentProposals::Executor.operator = nil
    AgentMessages::SlackRoutes.reset!
  end

  def reply(text, user: OWNER, thread_ts: ROOT)
    event = { "type" => "message", "channel" => CHAN, "channel_type" => "channel", "user" => user, "text" => text,
              "ts" => "1761900#{format('%03d', rand(1000))}.#{format('%06d', rand(1_000_000))}", "thread_ts" => thread_ts }.compact
    AgentMessages::SlackIngest.new.call(event, team_id: TEAM)
  end

  def run_jobs = perform_enqueued_jobs(only: AgentProposalJob)

  test "the owner's go in the thread runs the stored operation once and reports it in the thread" do
    go = reply("go")
    assert_equal [ "turf_monster", "thread", "confirmed" ], [ go.soul_slug, go.routed_by, @proposal.reload.status ]
    assert_equal "person:#{@owner.id}", @proposal.settled_by

    run_jobs

    assert_equal "executed", @proposal.reload.status
    call = @transport.calls.sole
    assert_equal "/_operator/contests/nfl-2026-weeks-8-10/cancel", call[:path]
    assert_equal "none", call[:body]["paid_entries"], "the params frozen at propose time"
    assert_match(/go on slack for agent proposal #{@proposal.id}/, @proposal.result["confirmed_by"])
    assert_match(/\ACancel of NFL Weeks 8-10 .* queued for your cosign: https:\/\/turf\.example\/admin\/pending_transactions/,
                 go.reload.response_text)
    assert_equal "queued", go.reply_status
    assert_enqueued_with(job: AgentMessageReplyJob, args: [ go.id ])
    executed = go.events.find_by(kind: "proposal_executed")
    assert_equal [ "cancel_contest", "queued" ], executed.detail.values_at("operation", "state")
    assert_equal @proposal.result["confirmed_by"], executed.detail["confirmed_by"]

    second = reply("go")
    run_jobs
    assert_equal 1, @transport.calls.size, "a double go runs once"
    assert second.events.exists?(kind: "proposal_closed")
  end

  test "a go that opens with a Slack mention of the app is still a go" do
    reply("<@#{APP_BOT}> go")
    assert_equal "confirmed", @proposal.reload.status
  end

  test "anyone but the owner is refused, and nothing runs" do
    held = reply("go", user: STRANGER)
    run_jobs
    assert_equal "held", held.status
    assert held.events.exists?(kind: "confirm_refused")
    assert_equal "proposed", @proposal.reload.status
    assert_empty @transport.calls
  end

  test "a top-level go, or a go in another thread, confirms nothing" do
    reply("go", thread_ts: nil)
    reply("go", thread_ts: "1761900999.000100")
    run_jobs
    assert_equal "proposed", @proposal.reload.status
    assert_empty @transport.calls
  end

  test "no drops it; nothing runs" do
    reply("no")
    run_jobs
    assert_equal "rejected", @proposal.reload.status
    assert_empty @transport.calls
  end

  test "Turf's refusal is posted in the thread and the proposal stays open" do
    @transport = Transport.new([ 422, { "error" => "paid_entries_need_choice",
                                        "message" => "NFL Weeks 8-10 has 3 paid entries. Say whether they are refunded or credited before it is cancelled." } ])
    AgentProposals::Executor.operator = AgentProposals::TurfOperator.new(
      env: { AgentProposals::TurfOperator::TOKEN_ENV => "t" }, base_url: "https://turf.example", transport: @transport
    )
    go = reply("go")
    assert_difference -> { ErrorLog.count }, 1 do
      run_jobs
    end
    assert_equal "proposed", @proposal.reload.status
    assert_equal "That did not run: Turf refused it: NFL Weeks 8-10 has 3 paid entries. Say whether they are refunded " \
                 "or credited before it is cancelled. Nothing changed. Reply **change: …** to revise it, or **no** to drop it.",
                 go.reload.response_text
  end

  test "with the endpoint not wired the thread is told why, and nothing is sent" do
    AgentProposals::Executor.operator = AgentProposals::TurfOperator.new(env: {}, base_url: "https://turf.example",
                                                                         transport: @transport)
    go = reply("go")
    run_jobs
    assert_match(/That did not run \(the Turf operator endpoint is not wired here \(OPERATOR_TOKEN_TURF_MONSTER is unset\)\)/,
                 go.reload.response_text)
    assert_empty @transport.calls
  end

  test "a proposal made in Slack records Slack as where it was asked, with the message's own link" do
    assert_equal "Slack", @proposal.requested_in
    assert_match(%r{/archives/#{CHAN}/p#{ROOT.delete('.')}\z}, @proposal.thread_url)
  end
end
