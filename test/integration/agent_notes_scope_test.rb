require "test_helper"
require "tmpdir"
require_relative "../support/agent_message_fixtures"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] Notes scoped by domain end to end, through the REAL API in process
# (docs/agents/system/agent-message-loop.md, "Whose memory"): a person tells Turf a
# fact → Turf's run returns it in its notes section → the board files it under
# Turf's domain → the same person writes to Avi → claim → GET context → the
# ContextBuilder prompt Avi's STUBBED Claude receives. A Turf client's note stays
# with Turf; an owner's note reaches Avi. Nothing reaches Discord, Claude or
# production.
class AgentNotesScopeTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures

  FACT = "Plays the Sunday contests.".freeze

  # Claude answers `answers` in turn, each in the json envelope; every prompt is kept.
  class EnvelopeRunner
    attr_reader :prompts

    def initialize(*answers)
      @answers = answers
      @prompts = []
    end

    def call(argv, stdin:, timeout:, chdir:)
      return [ "board: 2 building", 0 ] if stdin.nil?

      @prompts << stdin
      envelope = { "type" => "result", "subtype" => "success", "is_error" => false,
                   "result" => @answers[@prompts.size - 1] || "Hello." }
      [ JSON.generate(envelope), 0, "" ]
    end
  end

  setup do
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = AgentMailbox::Client.new(api: AgentMailboxInProcessApi.new(self, token))
    @out = StringIO.new
    @mailbox = Dir.mktmpdir("mailbox")
    @claude_home = Dir.mktmpdir("claude-home")
  end

  teardown { [ @mailbox, @claude_home ].each { |d| FileUtils.rm_rf(d) } }

  def answer(soul, runner)
    AgentMailbox::Heartbeat.new(soul: soul, client: @client, runner: runner, out: @out, claude_cmd: %w[fake-claude],
                                once: true, worker: "laptop-1", mailbox_home: @mailbox, claude_home: @claude_home).run
  end

  # The person tells Turf the fact, Turf's run files it, then the person writes
  # to Avi; returns [the Turf message, Avi's prompt].
  def fact_via_turf_then_ask_avi(author:, role:, client_domain: nil)
    told = agent_message!(soul: "turf_monster", author_ref: author, content: "I play every Sunday contest")
    told.person.set_role!(role, client_domain: client_domain)
    runner = EnvelopeRunner.new("Good luck Sunday!\n===NOTES===\n[\"#{FACT}\"]", "Hello.")
    answer("turf_monster", runner)
    assert_equal "completed", told.reload.status
    assert_equal [ [ FACT, "turf_monster" ] ], told.person.notes.map { |n| [ n.body, n.domain ] },
                 "the board files the fact under Turf's domain"

    agent_message!(soul: "avi", author_ref: author, content: "what do you know about me?")
    answer("avi", runner)
    [ told, runner.prompts.last ]
  end

  def user_layer(prompt) = prompt[/== USER: .*?(?=== PERSON)/m].to_s

  test "a Turf client's note filed via Turf does not reach Avi's prompt for that person" do
    told, prompt = fact_via_turf_then_ask_avi(author: "530", role: "client", client_domain: "turf_monster")

    refute_includes prompt, FACT, "Avi (mcritchie_studio) never reads what the Turf client told Turf"
    assert_includes user_layer(prompt), "(no notes about this person yet)"

    agent_message!(soul: "turf_monster", author_ref: "530", content: "and my contests?")
    runner = EnvelopeRunner.new("Sunday it is.")
    answer("turf_monster", runner)
    assert_includes user_layer(runner.prompts.last), FACT, "Turf still reads its own client's note"
    assert_equal told.person, AgentMessage.where(soul_slug: "turf_monster").order(:id).last.person
  end

  test "an owner's note filed via Turf reaches Avi's prompt" do
    _told, prompt = fact_via_turf_then_ask_avi(author: "531", role: "owner")

    assert_includes user_layer(prompt), FACT, "an owner's notes are shared by every soul in every domain"
  end
end
