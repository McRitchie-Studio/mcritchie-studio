require "test_helper"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] The CTO web chat end to end (docs/agents/system/agent-message-loop.md,
# "Web chat"): a signed-in owner posts on /applications/:slug/chat; the message is
# a `web` AgentMessage for that app's CTO; bin/dispatcher's loop (the REAL mailbox
# API in process, a stubbed Claude) claims it, pulses typing, answers, and the
# answer is pushed to the owner's chat stream, never to Discord. Plus the page
# gates: 404 for an app the viewer does not own, the visitor sent to sign in.
class CtoWebChatLoopTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  # Each Claude call waits for a token on `gate`, then answers.
  class GatedRunner
    attr_reader :prompts

    def initialize(gate:, answer:)
      @gate = gate
      @answer = answer
      @prompts = []
    end

    def call(_argv, stdin:, timeout:, chdir:)
      return [ "board: 2 building", 0 ] if stdin.nil?

      @prompts << stdin
      @gate.pop
      [ @answer, 0, "" ]
    end
  end

  setup do
    AgentPerson.seed_owner!
    @alex = users(:alex)
    @stranger = User.create!(email: "stranger@example.com", name: "Stranger", role: "viewer")
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = AgentMailbox::Client.new(api: AgentMailboxInProcessApi.new(self, token))
    @out = StringIO.new
    @now = Time.now
    @gate = Queue.new
    @discord = []
    @previous_transport = AgentMessages::DiscordBot.transport
    discord = @discord
    AgentMessages::DiscordBot.transport = ->(method, url, *_rest) { discord << [ method, url ] && [ 204, "" ] }
    @stream = AgentMessages::WebChat.stream_name("turf-monster", @alex.id)
  end

  teardown { AgentMessages::DiscordBot.transport = @previous_transport }

  def dispatcher(runner)
    # channel: nil is bin/dispatcher's default (`--channel all`): every channel, the web chat's included.
    AgentMailbox::Dispatcher.new(client: @client, souls: AgentMailbox.routed_souls, channel: nil, worker: "disp-web-1", runner: runner,
                                 claude_cmd: %w[fake-claude], out: @out, clock: -> { @now },
                                 sleeper: ->(_s) { }, idle_wait: 0, busy_wait: 0, version: "test")
  end

  def drive(disp, ticks: 300)
    ticks.times do
      disp.tick
      return if yield

      sleep 0.01
    end
    flunk "condition never held; log:\n#{@out.string}"
  end

  def sent = broadcasts(@stream).map { |payload| JSON.parse(payload) }

  test "[integration] owner posts, the dispatcher types and answers, and the answer streams into the chat" do
    log_in_as(@alex)
    post chat_application_path("turf-monster"), params: { cto_chat: { text: "How are signups?", client_id: "client-0001abcd" } },
                                                as: :turbo_stream
    assert_response :success
    assert_includes response.body, %(action="append" target="cto-chat-messages")
    assert_includes response.body, "How are signups?"

    message = AgentMessage.find_by!(channel: "web")
    assert_equal %w[turf_monster received web:turf-monster], [ message.soul_slug, message.status, message.thread_key.rpartition(":").first ]
    assert_equal 1, sent.size, "the new turn is broadcast to the owner's other tabs too"

    runner = GatedRunner.new(gate: @gate, answer: "Twelve signups this week.")
    disp = dispatcher(runner)
    perform_enqueued_jobs(only: [ AgentMessageTypingJob, AgentMessageReplyJob ]) do
      disp.tick
      assert_equal "claimed", message.reload.status, @out.string
      assert sent.last.include?("Turf is typing"), "the first pulse goes out with the claim"

      @now += AgentMailbox::Dispatcher::TYPING_EVERY
      disp.tick
      assert_equal 2, sent.count { |html| html.include?("is typing") }, "typing again every TYPING_EVERY"

      @gate << :go
      drive(disp) { message.reload.status == "completed" && disp.runs.empty? }
    end

    assert_match(/web chat on McRitchie Studio/, runner.prompts.first, "the prompt says where the message came from")
    assert_match(/You are speaking with: owner/, runner.prompts.first, "the owner's audience, from the person's role")
    assert_equal "posted", message.reload.reply_status
    assert sent.any? { |html| html.include?(%(target="cto-chat-turn-#{message.id}")) && html.include?("Twelve signups this week.") }
    assert_empty @discord, "a web answer never reaches Discord"

    get chat_application_path("turf-monster")
    assert_select "[data-test='cto-chat-turn'][data-status='completed'] [data-test='cto-chat-reply']", text: /Twelve signups/
  end

  test "[integration] the page and the post are 404 for an app the viewer does not own; a visitor signs in first" do
    get chat_application_path("turf-monster")
    assert_redirected_to %r{/login|/sign}

    log_in_as(@stranger)
    get chat_application_path("turf-monster")
    assert_response :not_found
    assert_no_difference -> { AgentMessage.count } do
      post chat_application_path("turf-monster"), params: { cto_chat: { text: "hi" } }, as: :turbo_stream
    end
    assert_response :not_found
  end

  test "[integration] an owner's chat reaches only their own app's CTO" do
    owner = User.create!(email: "owner@turf.example", name: "Turf Owner", role: "viewer")
    AppMembership.create!(app: apps(:turf_monster), user: owner)
    log_in_as(owner)

    post chat_application_path("turf-monster"), params: { cto_chat: { text: "hi", soul: "avi" } }, as: :turbo_stream
    assert_response :success
    assert_equal [ "turf_monster" ], AgentMessage.where(channel: "web").pluck(:soul_slug), "a soul param picks nothing"

    get chat_application_path("mcritchie-studio")
    assert_response :not_found
  end

  test "[integration] a refused message re-renders the form with the reason and keeps the text" do
    log_in_as(@alex)
    post chat_application_path("turf-monster"), params: { cto_chat: { text: "   " } }, as: :turbo_stream

    assert_response :unprocessable_content
    assert_includes response.body, %(action="replace" target="cto-chat-form")
    assert_includes response.body, "Write a message first."
    assert_equal 0, AgentMessage.count
  end
end
