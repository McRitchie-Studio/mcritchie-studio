require "test_helper"
require "tmpdir"
require Rails.root.join("bin/lib/agent_mailbox").to_s

# [unit] What a scoped grant changes in the Responder and the prompt: the owner
# gets the scoped command and is told his tools; a grant handed in for anyone
# else (it never should be) changes nothing; a warm turn is never scoped; the
# no-tools prompt says where tools are enabled.
class AgentScopePromptTest < ActiveSupport::TestCase
  S = AgentMailbox::Scopes

  class Runner
    attr_reader :calls

    def initialize = @calls = []

    def call(argv, stdin:, timeout:, chdir:)
      @calls << { argv: argv, stdin: stdin }
      stdin.nil? ? [ "BOARD", 0 ] : [ JSON.generate("type" => "result", "result" => "Answer."), 0, "" ]
    end
  end

  setup do
    @mailbox = Dir.mktmpdir("scope-prompt")
    @message = { "id" => 9, "channel" => "slack", "content" => "Mason, what breaks most?", "author_name" => "Alex McRitchie" }
    config = S::Config.load(Rails.root.to_s)
    @decision = S::Decision.new(grant: S::Grant.new(scope: config.scope_for("mason"), message_id: 9, worker: "w",
                                                    repo_root: Rails.root.to_s, max_turns: config.max_turns),
                                reason: "granted")
  end

  teardown { FileUtils.rm_rf(@mailbox) }

  def respond(role, decision: @decision, soul: "mason", warm: nil)
    runner = Runner.new
    responder = AgentMailbox::Responder.new(soul: soul, runner: runner, repo_root: Rails.root.to_s, mailbox_home: @mailbox,
                                            claude_cmd: AgentMailbox::Responder::DEFAULT_CLAUDE_CMD, claude_home: @mailbox)
    answer = responder.respond(@message, context: { "audience" => { "role" => role } }, scope: decision, warm: warm)
    [ answer, runner.calls.last ]
  end

  test "the owner's granted run gets the scoped command and the scoped rules" do
    answer, call = respond("owner")
    assert_includes call[:argv], "--mcp-config"
    assert_match(/Your tools \(read only, scope `mason`; there are no others\)/, call[:stdin])
    assert_match(/READ-ONLY tools inside your scope/, call[:stdin])
    refute_match(/You may take exactly ONE action/, call[:stdin])
    assert_equal "granted", answer.meta["scope"]
  end

  test "a grant handed in for anyone but the owner changes nothing" do
    %w[team client public].each do |role|
      answer, call = respond(role)
      assert_equal AgentMailbox::Responder::DEFAULT_CLAUDE_CMD, call[:argv], role
      refute_match(/READ-ONLY tools inside your scope|Your tools \(read only/, call[:stdin], role)
      assert_equal "not_owner", answer.meta["scope"], "the run record says the tools were not used"
    end
  end

  test "a denied decision runs the no-tools command and records why" do
    answer, call = respond("owner", decision: S.deny("not_cleared"))
    assert_equal AgentMailbox::Responder::DEFAULT_CLAUDE_CMD, call[:argv]
    assert_equal "not_cleared", answer.meta["scope"]
    assert_match(/enabled only when Alex McRitchie asks a scoped soul on Slack/, call[:stdin])
  end

  test "no decision at all is today's path, with no scope in the meta" do
    answer, call = respond("owner", decision: nil)
    assert_equal AgentMailbox::Responder::DEFAULT_CLAUDE_CMD, call[:argv]
    assert_nil answer.meta["scope"]
  end

  test "the prompt builder never tells a non-owner about tools, even with a grant" do
    text = AgentMailbox::ContextBuilder.new(soul: "mason", message: @message, repo_root: Rails.root.to_s,
                                            audience: AgentMailbox::Audience.new(role: "team"),
                                            scope: @decision.grant).prompt
    refute_match(/Your tools/, text)
    assert_match(/You may take exactly ONE action/, text)
  end
end
