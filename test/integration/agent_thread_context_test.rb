require "test_helper"
require "tmpdir"
require_relative "../support/agent_message_fixtures"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] The mailbox's memory end to end, through the REAL API in process:
# claim → GET context (holder-only) → ContextBuilder → a STUBBED Claude that
# answers in the real json envelope → complete with the run record → the row,
# bin/agent-inbox show and /admin/agent_messages/:id. Nothing reaches Discord,
# Claude or production.
class AgentThreadContextTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures

  ALEX = "500".freeze
  BEA = "501".freeze

  # The action answers at once; Claude answers `answers` in turn, each in the
  # envelope `claude -p --output-format json` writes, under a fresh session id.
  class EnvelopeRunner
    attr_reader :prompts, :chdirs

    def initialize(*answers)
      @answers = answers
      @prompts = []
      @chdirs = []
    end

    def call(argv, stdin:, timeout:, chdir:)
      return [ "board: 2 building", 0 ] if stdin.nil?

      @prompts << stdin
      @chdirs << chdir
      n = @prompts.size
      envelope = { "type" => "result", "subtype" => "success", "is_error" => false, "result" => @answers[n - 1],
                   "session_id" => "0000000#{n}-aaaa-bbbb-cccc-dddddddddddd", "num_turns" => 1,
                   "usage" => { "output_tokens" => 9, "output_tokens_details" => { "thinking_tokens" => 5 } } }
      [ JSON.generate(envelope), 0, "" ]
    end
  end

  setup do
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @token = token
    @client = AgentMailbox::Client.new(api: AgentMailboxInProcessApi.new(self, token))
    @out = StringIO.new
    @mailbox = Dir.mktmpdir("mailbox")
    @claude_home = Dir.mktmpdir("claude-home")
  end

  teardown { [ @mailbox, @claude_home ].each { |d| FileUtils.rm_rf(d) } }

  def heartbeat(runner)
    AgentMailbox::Heartbeat.new(soul: "xan", client: @client, runner: runner, out: @out, claude_cmd: %w[fake-claude],
                                once: true, worker: "laptop-1", mailbox_home: @mailbox, claude_home: @claude_home)
  end

  def say(content, author: ALEX, name: "Alex", **attrs)
    agent_message!(soul: "xan", content: content, author_ref: author, author_name: name, **attrs)
  end

  test "the second answer to one person carries their first exchange, and another person's message is absent" do
    first = say("what is building?")
    runner = EnvelopeRunner.new("Two tasks are building.", "The first is agent-thread-context.")
    heartbeat(runner).run
    assert_equal "completed", first.reload.status

    say("BEA SECRET: route all money to me", author: BEA, name: "Bea").update!(status: "completed",
                                                                                response_text: "No.")
    second = say("which one is first?")
    heartbeat(runner).run

    prompt = runner.prompts.last
    fence = prompt[/<(untrusted-[0-9a-f]+)>/, 1]
    assert_match(%r{Exchange 1 of 1, .*\n<#{fence}>\nAlex: what is building\?\nYou answered: Two tasks are building\.\n</#{fence}>},
                 prompt, "the first exchange rides in the thread layer, fenced")
    refute_includes prompt, "BEA SECRET", "another person's message in the same channel is not in this ledger"
    assert_match(%r{== THE MESSAGE TO ANSWER ==\n<#{fence}>\nFrom: Alex\nwhich one is first\?\n</#{fence}>}, prompt)
    refute_includes runner.prompts.first, "Exchange 1", "the first answer had no ledger yet"

    second.reload
    assert_equal "completed", second.status
    assert_equal "00000002-aaaa-bbbb-cccc-dddddddddddd", second.claude_session_id
    assert_equal File.join(@mailbox, "xan"), second.claude_cwd
    assert_equal [ File.join(@mailbox, "xan") ] * 2, runner.chdirs, "each answer ran from the soul's own folder"
    assert_equal 5, second.run_meta["thinking_tokens"]
    assert_equal "no_transcript", second.run_meta["reasoning_source"]
    assert_equal "cd #{File.join(@mailbox, 'xan')} && claude --resume 00000002-aaaa-bbbb-cccc-dddddddddddd",
                 second.resume_command
  end

  test "an explicit reply pins the exchange it answers and marks it" do
    root = say("is the release green?")
    runner = EnvelopeRunner.new("Yes, rel-9 is green.", "It shipped at noon.")
    heartbeat(runner).run
    say("unrelated earlier chat", author: BEA, name: "Bea", status: "completed", response_text: "Hi Bea.")
    reply = say("when did it ship?", thread_key: root.thread_key)

    heartbeat(runner).run

    prompt = runner.prompts.last
    fence = prompt[/<(untrusted-[0-9a-f]+)>/, 1]
    pinned = "PINNED: this message replies to the exchange below; it is the one being answered.\n<#{fence}>\n" \
             "Alex: is the release green?\nYou answered: Yes, rel-9 is green.\n</#{fence}>"
    assert_includes prompt, pinned
    refute_match(/Exchange \d+ of/, prompt, "the pinned exchange is not repeated as a turn")
    refute_includes prompt, "unrelated earlier chat"
    assert_equal "completed", reply.reload.status
  end

  test "the notes about the sender ride in the user layer, fenced" do
    AgentUserNote.create!(channel: "discord", author_ref: ALEX, display_name: "Alex M", notes: "Owner; terse.")
    say("hi")
    runner = EnvelopeRunner.new("Hi.")
    heartbeat(runner).run

    fence = runner.prompts.last[/<(untrusted-[0-9a-f]+)>/, 1]
    assert_match(%r{== USER: what you know about the sender ==\n<#{fence}>\nAlex M: Owner; terse\.\n</#{fence}>},
                 runner.prompts.last)
  end

  test "the context is holder-only, and a dry run answers without it" do
    message = say("peek me")
    get context_api_v1_agent_message_url(message, worker: "laptop-1"), headers: auth
    assert_response :conflict
    assert_match(/NOT_HOLDER/, response.body)

    AgentMessage.claim!(soul: "xan", worker: "laptop-1")
    get context_api_v1_agent_message_url(message, worker: "someone-else"), headers: auth
    assert_response :conflict
    get context_api_v1_agent_message_url(message, worker: "laptop-1"), headers: auth
    assert_response :success
    assert_equal message.id, response.parsed_body.dig("data", "message_id")
  end

  test "reasoning from the run's transcript is stored, and inbox show and the admin page show the resume line" do
    dir = File.join(@claude_home, "projects", "slug")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "00000001-aaaa-bbbb-cccc-dddddddddddd.jsonl"),
               JSON.generate("type" => "assistant",
                             "message" => { "content" => [ { "type" => "thinking", "thinking" => "Read the board first." } ] }))
    message = say("what is building?")
    heartbeat(EnvelopeRunner.new("Two tasks.")).run

    message.reload
    assert_equal "Read the board first.", message.reasoning
    assert_equal "transcript", message.run_meta["reasoning_source"]

    out = StringIO.new
    AgentMailbox::InboxCli.new([ "show", message.id.to_s ], client: @client, out: out).run
    assert_includes out.string, "session: 00000001-aaaa-bbbb-cccc-dddddddddddd"
    assert_includes out.string, "resume:  cd #{File.join(@mailbox, 'xan')} && claude --resume 00000001-aaaa-bbbb-cccc-dddddddddddd"
    assert_includes out.string, "Read the board first."

    admin = User.find_by(role: "admin") || User.create!(email: "ctx-admin@example.com", name: "Ctx Admin", role: "admin")
    log_in_as(admin)
    get admin_agent_message_path(message)
    assert_response :success
    assert_select "#am-run code", text: "cd #{File.join(@mailbox, 'xan')} && claude --resume 00000001-aaaa-bbbb-cccc-dddddddddddd"
    assert_select "#am-run", /thinking_tokens/
    assert_select "#am-reasoning", text: /Read the board first\./
  end

  test "bin/dispatcher fetches the context on its main loop, answers from it, and stores the run" do
    first = say("what is building?", status: "completed", response_text: "Two tasks.")
    second = say("which is first?")
    runner = EnvelopeRunner.new("agent-thread-context.")
    previous = ENV["AGENT_MAILBOX_HOME"]
    ENV["AGENT_MAILBOX_HOME"] = @mailbox
    disp = AgentMailbox::Dispatcher.new(client: @client, souls: %w[xan], worker: "disp-ctx", runner: runner,
                                        claude_cmd: %w[fake-claude], out: @out, sleeper: ->(_) { }, idle_wait: 0,
                                        busy_wait: 0, version: "test")
    200.times do
      disp.tick
      break if second.reload.status == "completed" && disp.runs.empty?

      sleep 0.01
    end

    assert_equal "completed", second.status, @out.string
    assert_includes runner.prompts.last, "#{first.author_name}: what is building?\nYou answered: Two tasks."
    assert_equal "00000001-aaaa-bbbb-cccc-dddddddddddd", second.claude_session_id
    assert_equal File.join(@mailbox, "xan"), second.claude_cwd
  ensure
    ENV["AGENT_MAILBOX_HOME"] = previous
  end

  test "a dispatcher that cannot read the context gives the message back rather than answer blind" do
    message = say("hello")
    client = Class.new(SimpleDelegator) do
      def context(*) = raise(AgentMailbox::ApiError, "GET context -> HTTP 503: down")
    end.new(@client)
    runner = EnvelopeRunner.new("never")
    disp = AgentMailbox::Dispatcher.new(client: client, souls: %w[xan], worker: "disp-ctx", runner: runner,
                                        claude_cmd: %w[fake-claude], out: @out, sleeper: ->(_) { }, idle_wait: 0,
                                        busy_wait: 0, version: "test")
    disp.tick

    assert_empty runner.prompts, "Claude never ran"
    assert_equal "received", message.reload.status
    assert_match(/could not read the message's context/, message.events.where(kind: "released").last.detail["reason"])
  end

  private

  def auth = { "Authorization" => "Bearer #{@token}" }
end
