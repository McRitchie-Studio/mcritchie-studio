require "test_helper"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] The Change flow over the CTO web chat, end to end, as Alex McRitchie will
# run it in production: signed in as alex@turfmonster.media (Turf Monster's
# owner), he asks Turf for a feature in the web chat; bin/dispatcher's loop (the
# real mailbox API in process, a stubbed Claude) answers with a PROPOSAL block;
# the board records it and the answer shows the confirm line with the capability
# and params, never the block; Alex McRitchie replies `go` in the same web thread; the
# proposal job opens a `designed` task whose source thread is the Turf web chat;
# and the result streams into the chat. A `go` in another web thread leaves the
# proposal alone. An app owner who is not Alex McRitchie may say go in their OWN app's chat
# (Alex McRitchie, 2026-10-18; AgentMessages::ProposalConfirm#owner_verdict); another
# owner's thread, a team-role owner, and another app's owner never run it.
class CtoWebChatChangeFlowTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  PROPOSAL = <<~TEXT.freeze
    I can open a task for that.
    ===PROPOSAL===
    {"kind": "change", "capability": "task", "params": {"title": "Show the slate's kickoff times", "accept": ["Each game row shows its kickoff time"], "test": ["[unit] kickoff time renders"]}, "summary": "Open a task to show kickoff times"}
  TEXT

  class Runner
    def initialize(answer) = @answer = answer

    def call(_argv, stdin:, timeout:, chdir:)
      return [ "", 0 ] if stdin.nil?

      [ @answer, 0, "" ]
    end
  end

  setup do
    AppMembership.delete_all
    @turf_alex = User.create!(email: "alex@turfmonster.media", name: "Alex", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: @turf_alex)
    @owner = AgentPerson.seed_owner! # links alex@turfmonster.media's web identity to the owner
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = AgentMailbox::Client.new(api: AgentMailboxInProcessApi.new(self, token))
    @out = StringIO.new
    @stream = AgentMessages::WebChat.stream_name("turf-monster", @turf_alex.id)
  end

  def answer_next(text)
    disp = AgentMailbox::Dispatcher.new(client: @client, souls: AgentMailbox.routed_souls, channel: nil, worker: "disp-change",
                                        runner: Runner.new(text), claude_cmd: %w[fake-claude], out: @out,
                                        clock: -> { Time.now }, sleeper: ->(_s) { }, idle_wait: 0, busy_wait: 0, version: "test")
    perform_enqueued_jobs(only: [ AgentMessageTypingJob, AgentMessageReplyJob ]) do
      300.times do
        disp.tick
        break if disp.runs.empty? && AgentMessage.where(channel: "web", status: %w[received claimed]).none?

        sleep 0.01
      end
    end
  end

  def say(text, app: "turf-monster")
    post chat_application_path(app), params: { cto_chat: { text: text } }, as: :turbo_stream
    assert_response :success
    AgentMessage.where(channel: "web").order(:id).last
  end

  def sent = broadcasts(@stream).map { |payload| JSON.parse(payload) }

  test "[integration] ask in the Turf web chat, Turf proposes, go in the same thread opens a designed task" do
    log_in_as(@turf_alex)
    ask = say("Can you show kickoff times on the slate?")
    assert_equal [ "received", @owner ], [ ask.status, ask.person ], "alex@turfmonster.media is the owner in the Turf chat"

    answer_next(PROPOSAL)
    ask.reload
    proposal = AgentProposal.find_by!(source_message: ask)
    assert_equal %w[proposed change task web turf_monster], [ proposal.status, proposal.kind, proposal.capability, proposal.channel, proposal.soul_slug ]
    assert_equal ask.thread_key, proposal.thread_key
    assert_no_match(/===PROPOSAL===|"capability"/, ask.response_text, "the block never reaches the chat")
    assert_includes ask.response_text, "> Proposed: Open a task to show kickoff times"
    assert_match(/> Runs: change `task` · .*title Show the slate's kickoff times/, ask.response_text, "the confirm line names the call")
    assert sent.any? { |html| html.include?("cto-chat-turn-#{ask.id}") && html.include?("Reply <strong>go</strong>") }

    # Another web thread (Alex McRitchie's admin account, its own thread with Turf) does not reach it.
    log_in_as(users(:alex))
    elsewhere = say("go")
    assert_not_equal ask.thread_key, elsewhere.thread_key
    assert_equal "proposed", proposal.reload.status, "a go in another thread confirms nothing"
    answer_next("Go where? There is nothing open here.")

    # The owner's go in the same web thread.
    log_in_as(@turf_alex)
    go = nil
    assert_difference -> { Task.count }, 1 do
      perform_enqueued_jobs(only: [ AgentProposalJob, AgentMessageReplyJob ]) { go = say("go") }
    end

    assert_equal "executed", proposal.reload.status
    task = Task.find_by!(slug: proposal.result["task_slug"])
    assert_equal "designed", task.stage
    assert_equal "Show the slate's kickoff times", task.title
    assert_equal "#{AgentProposal::BOARD_URL}/applications/turf-monster/chat", task.metadata.dig("devops", "source_thread")
    assert_includes task.description, "Requested in the turf-monster web chat: #{AgentProposal::BOARD_URL}/applications/turf-monster/chat"
    assert_includes task.description, "/admin/agent_messages/#{ask.id}"
    assert_not_includes task.description, "Discord"

    go.reload
    assert_equal "posted", go.reply_status
    assert_match(%r{\AOpened `#{task.slug}` #{Regexp.escape(AgentProposal::BOARD_URL)}/tasks/#{task.slug}}, go.response_text)
    assert sent.any? { |html| html.include?("cto-chat-turn-#{go.id}") && html.include?("/tasks/#{task.slug}") },
           "the task link streams into the chat"

    get chat_application_path("turf-monster")
    assert_select "#cto-chat-turn-#{go.id} [data-test='cto-chat-reply'] a[href$='/tasks/#{task.slug}']"
  end

  # A pending change proposal on `user`'s own Turf web thread, from their first message.
  def owner_proposal!(user)
    log_in_as(user)
    first = say("hello")
    AgentProposal.create!(thread_key: first.thread_key, channel: "web", guild_id: nil, channel_ref: "turf-monster",
                          soul_slug: "turf_monster", person: first.person, source_message: first, kind: "change",
                          capability: "task", params: { "title" => "Owner asked for this", "kind" => "feature", "shape" => "backend",
                                                        "accept" => [ "x" ], "test" => [ "[unit] x" ], "risk" => [] },
                          summary: "Open a task", status: "proposed", expires_at: 1.day.from_now)
  end

  test "[integration] an app owner who is not Alex McRitchie says go in their own Turf chat and the designed task opens" do
    partner = User.create!(email: "turf-partner@example.com", name: "Partner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: partner)
    proposal = owner_proposal!(partner)
    assert_equal "public", proposal.person.role, "an ordinary owner, answered by the app-owner rule"

    go = nil
    assert_difference -> { Task.count }, 1 do
      perform_enqueued_jobs(only: [ AgentProposalJob, AgentMessageReplyJob ]) { go = say("go") }
    end
    assert_equal "executed", proposal.reload.status
    task = Task.find_by!(slug: proposal.result["task_slug"])
    assert_equal [ "designed", "Owner asked for this" ], [ task.stage, task.title ]
    assert_match(/\AOpened `#{task.slug}`/, go.reload.response_text)

    get chat_application_path("turf-monster")
    assert_select "#cto-chat-turn-#{go.id} [data-test='cto-chat-reply'] a[href$='/tasks/#{task.slug}']"
  end

  test "[integration] another owner's go, a team-role owner's go, and another app's owner never run the proposal" do
    partner = User.create!(email: "turf-partner@example.com", name: "Partner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: partner)
    proposal = owner_proposal!(partner)

    co_owner = User.create!(email: "turf-co@example.com", name: "Co", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: co_owner)
    log_in_as(co_owner)
    assert_no_difference -> { Task.count } do
      perform_enqueued_jobs(only: AgentProposalJob) { assert_not_equal proposal.thread_key, say("go").thread_key }
    end

    studio_owner = User.create!(email: "studio-owner@example.com", name: "Studio", role: "viewer")
    AppMembership.create!(app: apps(:mcritchie_studio), user: studio_owner)
    log_in_as(studio_owner)
    post chat_application_path("turf-monster"), params: { cto_chat: { text: "go" } }, as: :turbo_stream
    assert_response :not_found, "an owner of another app has no Turf chat to say go in"

    proposal.person.set_role!("team")
    log_in_as(partner)
    assert_no_difference -> { Task.count } do
      perform_enqueued_jobs(only: AgentProposalJob) { assert_equal "held", say("go").status }
    end
    assert_equal "proposed", proposal.reload.status
  end
end
