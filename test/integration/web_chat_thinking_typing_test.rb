require "test_helper"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] Thinking, then typing, in the web chat (task
# chat-thinking-versus-typing; docs/agents/system/agent-message-loop.md, "Web
# chat"). bin/dispatcher's loop against the REAL mailbox API in process, with a
# Claude stand-in that replays a recorded stream-json run line by line through
# the runner's on_line seam: the claim's first pulse says thinking; the line
# that starts the answer's text sends a typing pulse on the loop's next beat
# (no 7-second wait); the answer is the stream's result; and the page's typing
# slot is cleared. A /build turn shows the same phases through its poll. A
# Discord run keeps its plain pulse and today's json command.
class WebChatThinkingTypingTest < ActionDispatch::IntegrationTest
  include ActionCable::TestHelper

  RECORDED = Rails.root.join("test/fixtures/files/claude_stream_thinking.jsonl").read.freeze
  RESULT = JSON.parse(RECORDED.lines.last).freeze

  # Replays the recorded stream: the lines before the answer's text, then (on
  # :text) the rest of the stream up to the result, then (on :finish) returns it.
  class StreamingRunner
    attr_reader :argvs

    def initialize(gate:)
      @gate = gate
      @argvs = []
    end

    def call(argv, stdin:, timeout:, chdir:, on_line: nil)
      return [ "board: 2 building", 0 ] if stdin.nil?

      @argvs << argv
      lines = RECORDED.lines
      split = lines.index { |l| AgentMailbox::ClaudeStream.phase_of(l) == "typing" }
      lines.first(split).each { |l| on_line&.call(l) }
      @gate.pop
      lines.drop(split).each { |l| on_line&.call(l) }
      @gate.pop
      [ RECORDED, 0, "" ]
    end
  end

  setup do
    AgentPerson.seed_owner!
    @alex = users(:alex)
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = AgentMailbox::Client.new(api: AgentMailboxInProcessApi.new(self, token))
    @out = StringIO.new
    @now = Time.now
    @gate = Queue.new
    @stream = AgentMessages::WebChat.stream_name("turf-monster", @alex.id)
  end

  def dispatcher(runner, client: @client, souls: AgentMailbox.routed_souls)
    AgentMailbox::Dispatcher.new(client: client, souls: souls, channel: nil, worker: "disp-phase-1", runner: runner,
                                 claude_cmd: AgentMailbox::Responder::DEFAULT_CLAUDE_CMD, out: @out, clock: -> { @now },
                                 sleeper: ->(_s) { }, idle_wait: 0, busy_wait: 0, version: "test")
  end

  def wait_for(what)
    300.times do
      return if yield

      sleep 0.01
    end
    flunk "#{what} never happened; log:\n#{@out.string}"
  end

  def drive(disp, ticks: 300)
    ticks.times do
      disp.tick
      return if yield

      sleep 0.01
    end
    flunk "condition never held; log:\n#{@out.string}"
  end

  def typing_broadcasts
    broadcasts(@stream).map { |payload| JSON.parse(payload) }
                       .select { |html| html.include?(%(target="#{AgentMessages::WebChat::TYPING_TARGET}")) }
  end

  test "[integration] a CTO chat answer shows thinking from the claim, typing as the text starts, then the answer" do
    log_in_as(@alex)
    post chat_application_path("turf-monster"), params: { cto_chat: { text: "Is 221 prime?", client_id: "client-phase-01" } },
                                                as: :turbo_stream
    message = AgentMessage.find_by!(channel: "web")
    runner = StreamingRunner.new(gate: @gate)
    disp = dispatcher(runner)

    perform_enqueued_jobs(only: [ AgentMessageTypingJob, AgentMessageReplyJob ]) do
      disp.tick
      assert_equal 1, typing_broadcasts.size, @out.string
      assert_includes typing_broadcasts.last, %(data-phase="thinking")
      assert_includes typing_broadcasts.last, "Turf is thinking"

      disp.tick
      assert_equal 1, typing_broadcasts.size, "no second pulse while the phase holds and TYPING_EVERY has not passed"

      @gate << :text
      wait_for("the typing phase") { disp.runs.first.phase.typing? }
      disp.tick
      assert_equal 2, typing_broadcasts.size, "the move to typing pulses at once, not on the 7-second tick"
      assert_includes typing_broadcasts.last, %(data-phase="typing")
      assert_includes typing_broadcasts.last, "Turf is typing"

      disp.tick
      assert_equal 2, typing_broadcasts.size, "one pulse per change"
      @now += AgentMailbox::Dispatcher::TYPING_EVERY
      disp.tick
      assert_equal 3, typing_broadcasts.size, "the 7-second pulse goes on, still typing"
      assert_includes typing_broadcasts.last, %(data-phase="typing")

      @gate << :finish
      drive(disp) { message.reload.status == "completed" && disp.runs.empty? }
    end

    assert_includes runner.argvs.sole, AgentMailbox::ClaudeStream::PARTIAL
    assert_includes runner.argvs.sole, "--safe-mode"
    assert_equal [ "--tools", "" ], runner.argvs.sole.each_cons(2).find { |a, _| a == "--tools" }
    message.reload
    assert_equal RESULT["result"].strip, message.response_text, "the answer is the stream's result line"
    assert_equal RESULT["session_id"], message.claude_session_id
    assert_equal RESULT.dig("usage", "output_tokens"), message.run_meta["output_tokens"], "usage reaches the meter as before"
    assert_includes typing_broadcasts.last, "<template></template>", "the answer clears the indicator"
  end

  test "[integration] a /build turn's poll draws thinking, then typing, from the pulses on its row" do
    proof = BrowserProof.new(BuildController::PROOF_PURPOSE).issue(5.seconds.ago).reverse
    post build_path, params: { app_request: { prompt: "A league site with standings", client_id: "ray-phase-1", form_proof: proof } }
    request_row = AppRequest.recent.first
    message = AgentMessage.find_by!(thread_key: BuildIntake.thread_key(request_row.token))
    poll = -> { get build_request_turns_path(request_row.token, ids: message.id.to_s), as: :turbo_stream }

    poll.call
    assert_includes response.body, %(data-phase="thinking"), "a turn nobody has picked up yet is thinking"

    disp = dispatcher(StreamingRunner.new(gate: @gate), souls: [ BuildIntake.soul ])
    perform_enqueued_jobs(only: [ AgentMessageTypingJob, AgentMessageReplyJob ]) do
      disp.tick
      assert_equal "claimed", message.reload.status, @out.string
      assert_equal "thinking", message.typing_phase

      @gate << :text
      wait_for("the typing phase") { disp.runs.first.phase.typing? }
      disp.tick
      assert_equal "typing", message.reload.typing_phase
      poll.call
      assert_includes response.body, %(data-phase="typing")
      assert_includes response.body, "Ray is typing"

      @gate << :finish
      drive(disp) { message.reload.status == "completed" && disp.runs.empty? }
    end

    poll.call
    assert_not_includes response.body, %(data-test="cto-chat-typing"), "an answered turn shows no indicator"
    assert_nil message.reload.typing_phase, "complete! wrote the run's own summary over the phase"
  end

  # [unit] Discord keeps its plain pulse: no phase in the call, and the run
  # stays on today's json command even with a runner that could stream.
  class DiscordClient
    attr_reader :typing_args

    def initialize = @typing_args = []

    def claim(**)
      return { "data" => nil } if @handed

      @handed = true
      { "data" => { "id" => 41, "soul_slug" => "avi", "channel" => "discord", "attempts" => 1 } }
    end

    def context(*, **) = { "data" => {} }

    def typing(id, worker:, **rest)
      @typing_args << rest
      { "meta" => { "typing" => "queued" } }
    end

    def complete(*, **) = { "meta" => { "outcome" => "completed" } }
    def renew(*, **) = {}
    def ping(*) = {}
    def release(*, **) = {}
  end

  test "[unit] a Discord run pulses with no phase and runs the json command" do
    client = DiscordClient.new
    argvs = []
    runner = lambda do |argv, stdin:, timeout:, chdir:, on_line: nil|
      argvs << argv unless stdin.nil?
      [ JSON.generate(RESULT), 0, "" ]
    end
    disp = dispatcher(runner, client: client, souls: %w[avi])

    drive(disp) { argvs.any? && disp.runs.empty? }
    assert_equal [ {} ], client.typing_args
    assert_equal AgentMailbox::Responder::DEFAULT_CLAUDE_CMD, argvs.sole
  end
end
