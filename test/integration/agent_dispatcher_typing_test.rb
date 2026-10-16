require "test_helper"
require_relative "../support/agent_message_fixtures"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] "typing…" while bin/dispatcher answers (docs/agents/system/agent-message-loop.md,
# "Typing"): the dispatcher's loop against the REAL mailbox API in process, a
# stubbed Claude, and Discord's HTTP stubbed at AgentMessages::DiscordBot's one
# seam. A claimed message pulses typing at once and every TYPING_EVERY while the
# run lives, then the reply posts, as the same bot; pulses stop with the run
# (a failure) and at TYPING_CAP. [unit] The dispatcher's side of a board "no".
class AgentDispatcherTypingTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures

  # Each Claude call waits for a token on `gate`, then answers.
  class GatedRunner
    def initialize(gate:, answer: "Two tasks are building.", status: 0)
      @gate = gate
      @answer = answer
      @status = status
    end

    def call(_argv, stdin:, timeout:, chdir:)
      return [ "board: 2 building", 0 ] if stdin.nil?

      @gate.pop
      [ @answer, @status, "" ]
    end
  end

  setup do
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = AgentMailbox::Client.new(api: AgentMailboxInProcessApi.new(self, token))
    @out = StringIO.new
    @now = Time.now
    @gate = Queue.new
    @calls = []
    @previous_transport = AgentMessages::DiscordBot.transport
    calls = @calls
    AgentMessages::DiscordBot.transport = lambda do |method, url, headers, _body|
      calls << { method: method, path: url.delete_prefix(AgentMessages::DiscordBot::API), auth: headers["Authorization"] }
      url.end_with?("/typing") ? [ 204, "" ] : [ 200, JSON.generate("id" => "880000000000000777") ]
    end
  end

  teardown { AgentMessages::DiscordBot.transport = @previous_transport }

  def dispatcher(runner, client: @client)
    AgentMailbox::Dispatcher.new(client: client, souls: %w[avi], worker: "disp-typing-1", runner: runner,
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

  def typing_calls = @calls.select { |c| c[:path].end_with?("/typing") }

  test "[integration] a claimed message types at once, again every TYPING_EVERY, then the reply posts as the same bot" do
    message = agent_message!(soul: "avi")
    disp = dispatcher(GatedRunner.new(gate: @gate))

    with_env("DISCORD_AGENT_BOT_TOKEN", "shared-token") do
      with_env("DISCORD_BOT_TOKEN_AVI", "avi-token") do
        perform_enqueued_jobs(only: [ AgentMessageTypingJob, AgentMessageReplyJob ]) do
          disp.tick
          assert_equal 1, typing_calls.size, "the first pulse goes out with the claim"

          @now += AgentMailbox::Dispatcher::TYPING_EVERY - 1
          disp.tick
          assert_equal 1, typing_calls.size, "not before TYPING_EVERY"

          @now += 1
          disp.tick
          assert_equal 2, typing_calls.size

          @gate << :go
          drive(disp) { message.reload.status == "completed" && disp.runs.empty? }
          @now += AgentMailbox::Dispatcher::TYPING_EVERY * 3
          3.times { disp.tick }
        end
      end
    end

    assert_equal [ "/channels/#{DESK}/typing" ] * 2 + [ "/channels/#{DESK}/messages" ], @calls.map { |c| c[:path] },
                 "typing, typing, then the reply, and no pulse after it"
    assert_equal [ "Bot avi-token" ], @calls.map { |c| c[:auth] }.uniq, "typing and reply are the same bot"
    assert_equal "posted", message.reload.reply_status
    refute_match(/avi-token|shared-token/, @out.string, "no token reaches the dispatcher log")
  end

  test "[integration] typing stops when the run fails, and the message is given back" do
    message = agent_message!(soul: "avi")
    disp = dispatcher(GatedRunner.new(gate: @gate, answer: "", status: 1))

    with_env("DISCORD_AGENT_BOT_TOKEN", "shared-token") do
      perform_enqueued_jobs(only: AgentMessageTypingJob) do
        disp.tick
        @gate << :go
        drive(disp) { disp.runs.empty? }
        5.times do
          @now += AgentMailbox::Dispatcher::TYPING_EVERY
          disp.tick
        end
      end
    end

    assert_equal 1, typing_calls.size
    assert_equal "received", message.reload.status
  end

  test "[integration] a run that outlives TYPING_CAP stops asking for typing" do
    message = agent_message!(soul: "avi")
    disp = dispatcher(GatedRunner.new(gate: @gate))
    every = AgentMailbox::Dispatcher::TYPING_EVERY
    cap = AgentMailbox::Dispatcher::TYPING_CAP

    disp.tick
    ((cap / every) + 5).times do
      @now += every
      disp.tick
    end

    assert_enqueued_jobs (cap / every) + 1, only: AgentMessageTypingJob
    assert_equal false, disp.runs.first.typing
    @gate << :go
    drive(disp) { message.reload.status == "completed" }
  end

  # [unit] The dispatcher's half: a board "no" (capped, not answered) or a
  # refusal stops that run's pulses, and the answer goes on.
  class FakeClient
    attr_reader :typing_calls, :completed

    def initialize(verdicts)
      @verdicts = verdicts
      @typing_calls = 0
      @handed = false
      @completed = []
    end

    def claim(**)
      return { "data" => nil } if @handed

      @handed = true
      { "data" => { "id" => 41, "soul_slug" => "avi", "channel" => "discord", "attempts" => 1 } }
    end

    def context(*, **) = { "data" => {} }

    def typing(_id, worker:)
      @typing_calls += 1
      verdict = @verdicts.shift
      raise AgentMailbox::ApiError, "POST typing -> HTTP 409: NOT_HOLDER" if verdict == :raise
      raise Errno::ECONNRESET, "board connection reset" if verdict == :boom

      { "meta" => { "typing" => verdict } }
    end

    def complete(id, **) = @completed << id && { "meta" => { "outcome" => "completed" } }
    def renew(*, **) = {}
    def ping(*) = {}
    def release(*, **) = {}
  end

  [ [ "capped", "stopped (capped)" ], [ "not_answered", "stopped (not_answered)" ], [ :raise, "refused" ],
    [ :boom, "failed (Errno::ECONNRESET)" ] ].each do |verdict, logged|
    test "[unit] the board answering #{verdict} stops that run's typing; the answer still completes" do
      client = FakeClient.new([ "queued", verdict ])
      disp = dispatcher(GatedRunner.new(gate: @gate), client: client)

      disp.tick
      3.times do
        @now += AgentMailbox::Dispatcher::TYPING_EVERY
        disp.tick
      end
      assert_equal 2, client.typing_calls
      assert_match(/typing for #41 #{Regexp.escape(logged)}/, @out.string)

      @gate << :go
      drive(disp) { client.completed == [ 41 ] }
    end
  end
end
