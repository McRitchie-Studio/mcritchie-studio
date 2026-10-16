require "test_helper"
require_relative "../support/agent_message_fixtures"

# [unit] AgentProposalJob and the queries it runs: a confirmed ask posts the
# query's deterministic text, a failed run leaves the proposal open with an
# ErrorLog row, and a proposal that is not confirmed never runs.
class AgentProposalJobTest < ActiveJob::TestCase
  include AgentMessageFixtures

  setup do
    @go = agent_message!(soul: "xan", status: "completed", content: "go")
    @proposal = AgentProposal.create!(thread_key: @go.thread_key, channel: "discord", guild_id: GUILD, channel_ref: DESK,
                                      soul_slug: "xan", kind: "ask", capability: "board_status", params: {},
                                      summary: "Count", status: "confirmed", confirm_message: @go,
                                      expires_at: 1.day.from_now)
  end

  test "a confirmed ask runs once and its text is queued as the answer" do
    Task.create!(title: "Alpha Beta Gamma Delta", stage: "designed")
    Task.create!(title: "Epsilon Zeta Eta Theta", stage: "building", blocked_at: Time.current, block_kind: "rework")
    AgentProposalJob.perform_now(@proposal.id)
    assert_equal "executed", @proposal.reload.status
    text = @go.reload.response_text
    assert_match(/\ABoard now: designed \d+ · building \d+ · submitted \d+ · reviewed \d+ · assembled \d+ · shipped \d+/, text)
    assert_match(/\(\d+ blocked\)\.\z/, text)
    assert_equal "queued", @go.reply_status
    assert_enqueued_with(job: AgentMessageReplyJob, args: [ @go.id ])

    AgentProposalJob.perform_now(@proposal.id)
    assert_equal 1, @go.events.where(kind: "proposal_executed").count, "a retried job does nothing"
  end

  test "a failed run leaves the proposal open, logs it, and says so in one line" do
    broken = Object.new
    def broken.run = raise(ActiveRecord::StatementInvalid, "PG::Error password=hunter2")
    assert_difference -> { ErrorLog.count }, 1 do
      AgentProposalJob.perform_now(@proposal.id, executor: broken)
    end
    assert_equal [ "proposed", nil ], [ @proposal.reload.status, @proposal.confirm_message_id ]
    assert_equal "That did not run (StatementInvalid). The proposal is still open: reply **go** to try again, or **no** to drop it.",
                 @go.reload.response_text
    refute_includes @go.response_text, "hunter2"
    assert @go.events.exists?(kind: "proposal_failed")
  end

  test "a proposal that is not confirmed never runs" do
    @proposal.update!(status: "proposed")
    AgentProposalJob.perform_now(@proposal.id)
    assert_nil @go.reload.response_text
    assert_no_enqueued_jobs only: AgentMessageReplyJob
  end

  test "recently_shipped lists what shipped in the window" do
    task = Task.create!(title: "Shipped Thing Works Well", stage: "designed")
    task.update_columns(stage: "shipped", completed_at: 2.days.ago)
    text = AgentProposals::Queries.run("recently_shipped", { "days" => 7 })
    assert_match(/\AShipped in the last 7 days \(\d+\):/, text)
    assert_includes text, "`#{task.slug}` Shipped Thing Works Well"
    assert_raises(AgentProposals::Queries::Unknown) { AgentProposals::Queries.run("drop_tables", {}) }
  end

  test "an unwired satellite says so instead of a number" do
    with_env("HEALTH_TOKEN_TURF_MONSTER", nil) do
      text = AgentProposals::Queries.run("app_health", { "days" => 1 }, app: "turf-monster")
      assert_equal "Turf Monster: its health report is not wired here, so I have no numbers.", text
    end
  end
end
