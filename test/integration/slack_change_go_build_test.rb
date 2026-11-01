require "test_helper"
require_relative "../support/agent_message_fixtures"

# [integration] Build from Slack (docs/agents/system/client-build-launcher.md,
# "Change cards"): Avi's change proposal in a Slack thread, confirmed by Alex
# McRitchie's own `go` there, opens the designed hub card, the go answer says the
# build launcher starts it, and the card is a launcher candidate whose start posts
# back into the same thread. Anyone else's go opens and starts nothing.
class SlackChangeGoBuildTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include AgentMessageFixtures

  TEAM = "T0CC9DQ9NAK".freeze      # the shipped slack.team_id
  CHAN = "C0CD8ETBZBM".freeze
  OWNER = "U0CCSMUMQJV".freeze     # Alex McRitchie (slack.owner_user_id)
  STRANGER = "U0STRANGE1".freeze
  ROOT = "1761950000.000100".freeze

  setup do
    AgentMessages::SlackRoutes.reset!
    @owner = AgentPerson.seed_owner!
    @answer = AgentMessage.create!(channel: "slack", external_id: "#{CHAN}:#{ROOT}", guild_id: TEAM, channel_ref: CHAN,
                                   thread_key: "slack:#{CHAN}:#{ROOT}", author_ref: OWNER, author_name: "Alex",
                                   person: @owner, content: "Avi, combine the admin sidebar links into one page",
                                   soul_slug: "avi", routed_by: "name", status: "completed")
    @proposal = AgentProposal.create!(
      thread_key: @answer.thread_key, channel: "slack", guild_id: TEAM, channel_ref: CHAN, soul_slug: "avi",
      person: @owner, source_message: @answer, kind: "change", capability: "task",
      params: { "title" => "Combine Admin Sidebar Links", "kind" => "feature", "shape" => "ui-only",
                "accept" => [ "Admins see one Admin link" ], "test" => [ "[unit] the admin page lists every link" ],
                "risk" => [ "System tests or shared layouts may depend on the current admin sidebar links" ] },
      summary: "Open a task to combine the admin links", expires_at: 1.day.from_now
    )
  end

  teardown { AgentMessages::SlackRoutes.reset! }

  def reply(text, user: OWNER)
    event = { "type" => "message", "channel" => CHAN, "channel_type" => "channel", "user" => user, "text" => text,
              "ts" => "1761950#{format('%03d', rand(1000))}.#{format('%06d', rand(1_000_000))}", "thread_ts" => ROOT }
    AgentMessages::SlackIngest.new.call(event, team_id: TEAM)
  end

  def run_jobs = perform_enqueued_jobs(only: AgentProposalJob)

  test "the owner's go opens the hub card, says the launcher starts it, and the start posts in the thread" do
    go = reply("go")
    run_jobs

    slug = @proposal.reload.result["task_slug"]
    task = Task.find_by!(slug: slug)
    assert_equal [ "designed", [ "mcritchie-studio" ] ], [ task.stage, task.devops["repositories"] ]
    assert_equal [ "System tests or shared layouts may depend on the current admin sidebar links" ], task.devops["risk_tags"]
    assert_includes go.reload.response_text, "Opened `#{slug}`"
    assert_includes go.response_text, AgentProposals::Executor::STARTS_TEXT.strip
    assert_equal [ slug ], ChangeBuilds.candidates.map { |c| c["task_slug"] }

    ChangeBuilds.claim!(slug, worker: "mac", run: "r1")
    ChangeBuilds.finish!(slug, run: "r1", outcome: "started", desk: "/Users/alex/projects/mcritchie-studio/.worktrees/#{slug}")
    line = AgentMessage.find_by!(channel: "slack", external_id: "change-build:#{slug}:started")
    assert_equal [ @answer.thread_key, CHAN, "queued" ], [ line.thread_key, line.channel_ref, line.reply_status ]
    assert_enqueued_with(job: AgentMessageReplyJob, args: [ line.id ])
  end

  test "a double go opens one card and offers it to the launcher once" do
    reply("go")
    run_jobs
    second = reply("go")
    run_jobs

    assert_equal 1, Task.where("title LIKE ?", "Combine Admin Sidebar Links%").count
    assert second.events.exists?(kind: "proposal_closed")
    assert_equal 1, ChangeBuilds.candidates.size
  end

  test "a stranger's go is held: no card, no build" do
    held = reply("go", user: STRANGER)
    run_jobs

    assert_equal "held", held.status
    assert_equal "proposed", @proposal.reload.status
    assert_empty ChangeBuilds.candidates
  end

  test "an owner-role person on another Slack id opens the card but it is never started" do
    other = AgentPerson.create!(display_name: "Second owner").tap { |p| p.set_role!("owner") }
    other.identities.create!(platform: "slack", external_id: STRANGER, display_name: "Second owner")
    go = reply("go", user: STRANGER)
    run_jobs

    slug = @proposal.reload.result["task_slug"]
    assert Task.exists?(slug: slug), "ProposalConfirm let the owner role confirm"
    refute_includes go.reload.response_text, AgentProposals::Executor::STARTS_TEXT.strip
    assert_empty ChangeBuilds.candidates, "only the configured owner Slack user's go starts a build"
  end
end
