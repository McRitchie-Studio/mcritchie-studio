require "test_helper"
require_relative "../support/agent_message_fixtures"

# [unit] AgentProposalJob and the queries it runs: a confirmed ask posts the
# query's deterministic text, a failed run leaves the proposal open with an
# ErrorLog row, and a proposal that is not confirmed never runs.
class AgentProposalJobTest < ActiveJob::TestCase
  include AgentMessageFixtures

  setup do
    @go = agent_message!(soul: "avi", status: "completed", content: "go")
    @proposal = AgentProposal.create!(thread_key: @go.thread_key, channel: "discord", guild_id: GUILD, channel_ref: DESK,
                                      soul_slug: "avi", kind: "ask", capability: "board_status", params: {},
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

  # Records how many transactions were open when it ran: the job's own claim
  # and settle transactions must both be closed while it runs.
  class DepthProbe
    attr_reader :depth, :runs

    def initialize = @runs = 0

    def run
      @runs += 1
      @depth = AgentProposal.connection.open_transactions
      [ "ran", { "query" => "probe" } ]
    end
  end

  test "the run holds no row lock: claim and settle are separate transactions" do
    baseline = AgentProposal.connection.open_transactions
    probe = DepthProbe.new
    AgentProposalJob.perform_now(@proposal.id, executor: probe)
    assert_equal baseline, probe.depth, "no transaction (so no FOR UPDATE lock) is open during the run"
    assert_equal [ "executed", "ran" ], [ @proposal.reload.status, @go.reload.response_text ]
  end

  test "a live claim makes a duplicate job do nothing; a stale one is taken again" do
    @proposal.update!(result: { "claim" => "other", "claimed_at" => 1.minute.ago.iso8601 })
    probe = DepthProbe.new
    AgentProposalJob.perform_now(@proposal.id, executor: probe)
    assert_equal [ 0, "confirmed" ], [ probe.runs, @proposal.reload.status ]

    @proposal.update!(result: { "claim" => "other", "claimed_at" => (AgentProposalJob::CLAIM_TTL + 1.minute).ago.iso8601 })
    AgentProposalJob.perform_now(@proposal.id, executor: probe)
    assert_equal [ 1, "executed" ], [ probe.runs, @proposal.reload.status ]
  end

  # Not a StandardError: what a worker killed mid-run looks like to the job.
  class WorkerKilled < Exception; end # rubocop:disable Lint/InheritException

  test "a worker killed mid-run is retaken by the recheck scheduled at claim expiry" do
    killer = Object.new
    def killer.run = raise(WorkerKilled)
    freeze_time do
      assert_raises(WorkerKilled) { AgentProposalJob.perform_now(@proposal.id, executor: killer) }
      assert_equal "confirmed", @proposal.reload.status, "stranded: confirmed, with a live claim"
      assert_enqueued_with(job: AgentProposalJob, args: [ @proposal.id ],
                           at: AgentProposalJob::CLAIM_TTL.from_now + AgentProposalJob::RECHECK_MARGIN)
    end

    # A retry inside the TTL sees the live claim and exits: the old strand.
    probe = DepthProbe.new
    AgentProposalJob.perform_now(@proposal.id, executor: probe)
    assert_equal [ 0, "confirmed" ], [ probe.runs, @proposal.reload.status ]

    # The recheck, at its scheduled time, retakes the expired claim and runs it.
    travel(AgentProposalJob::CLAIM_TTL + AgentProposalJob::RECHECK_MARGIN + 1.second) do
      AgentProposalJob.perform_now(@proposal.id, executor: probe)
    end
    assert_equal [ 1, "executed", "ran" ], [ probe.runs, @proposal.reload.status, @go.reload.response_text ]
  end

  test "the recheck after a settled run does nothing" do
    AgentProposalJob.perform_now(@proposal.id, executor: DepthProbe.new)
    assert_equal "executed", @proposal.reload.status
    probe = DepthProbe.new
    travel(AgentProposalJob::CLAIM_TTL + AgentProposalJob::RECHECK_MARGIN + 1.second) do
      AgentProposalJob.perform_now(@proposal.id, executor: probe)
    end
    assert_equal 0, probe.runs
  end

  # A result whose to_h raises: the run succeeded, then settling blew up.
  class BadResult
    def to_h = raise(RuntimeError, "settle broke")
    def as_json(*) = {}
  end

  test "an error while settling writes an ErrorLog targeted at the go, then raises" do
    breaker = Object.new
    def breaker.run = [ "ran", BadResult.new ]
    assert_difference -> { ErrorLog.where(target: @go).count }, 1 do
      assert_raises(RuntimeError) { AgentProposalJob.new.perform(@proposal.id, executor: breaker) }
    end
    assert_equal "settle broke", ErrorLog.where(target: @go).last.message
    assert_equal "confirmed", @proposal.reload.status, "rolled back: the recheck will retake it"
  end

  test "a run whose claim was taken over meanwhile does not settle" do
    thief = Object.new
    proposal = @proposal
    thief.define_singleton_method(:run) do
      proposal.update_columns(result: { "claim" => "someone-else", "claimed_at" => Time.current.iso8601 })
      [ "late", {} ]
    end
    AgentProposalJob.perform_now(@proposal.id, executor: thief)
    assert_equal "confirmed", @proposal.reload.status
    assert_nil @go.reload.response_text, "nothing posts for a lost claim"
  end

  test "release_status reads the ladder and the active release in process" do
    Task.create!(title: "Reviewed Task Waits Here", stage: "designed").update_columns(stage: "reviewed")
    release = Release.open!
    text = AgentProposals::Queries.run("release_status", {})
    assert_match(/\ARelease now: `#{Regexp.escape(release.slug)}` assembling(, stage [a-z ]+)?, \d+ tasks? aboard\. /, text)
    assert_match(/Ladder: submitted \d+ · reviewed [1-9]\d* · assembled \d+\./, text)

    release.update!(state: "abandoned")
    assert_match(/\ANo release is open\. Ladder: /, AgentProposals::Queries.run("release_status", {}))
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
