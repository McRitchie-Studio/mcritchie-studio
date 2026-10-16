require "test_helper"
require "tmpdir"
require "zlib"
require_relative "../support/agent_message_fixtures"
require_relative "../support/agent_mailbox_in_process_api"
require Rails.root.join("bin/lib/agent_dispatcher").to_s

# [integration] Warm sessions end to end (docs/agents/system/agent-message-loop.md,
# "Warm sessions"): bin/dispatcher's loop against the REAL board API in process,
# with a fake Claude that keeps real transcripts on disk and refuses a --resume
# whose transcript this "machine" does not have, as the CLI does. Two machines
# are two dispatchers with their own Claude homes and hosts.
#
#   owner message, flag on   → a fresh session, then a resumed turn; checkpoints on the board
#   the primary lapses       → the standby takes the lease, restores, resumes
#   handback                 → only between turns; the primary resumes the standby's head
#   client message, flag on  → one run per message, no lease
#   consolidation            → a summary row, then a fresh seeded session
#   flag off                 → today's path: no lease, no --resume
class AgentDispatcherWarmTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures
  include ActiveSupport::Testing::TimeHelpers

  DOMAIN = "mcritchie_studio".freeze

  # Claude as the CLI behaves for these runs: --resume needs the session's
  # transcript in this cwd's project folder; each run writes a NEW session id
  # holding the whole history (the fork the dispatcher must follow). `gate`
  # holds a run until a token arrives.
  class FakeClaude
    attr_reader :calls

    def initialize(home, tokens: 1_000, gate: nil)
      @home = home
      @tokens = tokens
      @gate = gate
      @calls = Queue.new
      @seq = 0
      @lock = Mutex.new
    end

    def call(argv, stdin:, timeout:, chdir:)
      return [ "board: 2 building", 0 ] if stdin.nil?

      @calls << { argv: argv, stdin: stdin }
      @gate&.pop
      resume = argv.include?("--resume") ? argv[argv.index("--resume") + 1] : nil
      dir = AgentMailbox::WarmSession.project_dir(chdir, claude_home: @home)
      prior = ""
      if resume
        path = File.join(dir, "#{resume}.jsonl")
        unless File.file?(path)
          return [ JSON.generate("type" => "result", "subtype" => "error_during_execution", "is_error" => true,
                                 "result" => "No conversation found with session ID: #{resume}"), 1, "" ]
        end
        prior = File.read(path)
      end
      sid = @lock.synchronize { "sess-#{object_id}-#{@seq += 1}" }
      summary = stdin.start_with?("This session has grown long")
      answer = summary ? "Owner asked about the release." : "Answered."
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "#{sid}.jsonl"),
                 prior + JSON.generate("type" => "user", "message" => { "content" => stdin[0, 40] }) + "\n" +
                 JSON.generate("type" => "assistant", "message" => { "content" => [ { "type" => "text", "text" => answer } ] }) + "\n")
      [ JSON.generate("type" => "result", "subtype" => "success", "is_error" => false, "result" => answer,
                      "session_id" => sid, "num_turns" => 1,
                      "usage" => { "input_tokens" => 10, "cache_read_input_tokens" => @tokens,
                                   "cache_creation_input_tokens" => 0, "output_tokens" => 5 }), 0, "" ]
    end

    def all_calls
      list = []
      list << @calls.pop until @calls.empty?
      list
    end
  end

  setup do
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = AgentMailbox::Client.new(api: AgentMailboxInProcessApi.new(self, token))
    @tmp = Dir.mktmpdir("warm-int")
    config = YAML.safe_load_file(Rails.root.join("config/agent_domains.yml"), aliases: false)
    config["domains"][DOMAIN]["warm_session"] = true
    config["domains"][DOMAIN]["consolidate_at"] = 50_000
    @warm = AgentMailbox::DomainRegistry.new(config)
    AgentProposal.registry = @warm
    @owner = AgentPerson.create!(display_name: "Alex", role: "owner")
    @client_person = AgentPerson.create!(display_name: "Client", role: "client", client_domain: "turf_monster")
    @now = Time.now
    @out = StringIO.new
  end

  teardown do
    AgentProposal.reset_registry!
    FileUtils.rm_rf(@tmp)
  end

  def machine(name, claude:, registry: @warm, host: name)
    AgentMailbox::Dispatcher.new(client: @client, souls: %w[avi xan], worker: "#{name}-worker", runner: claude,
                                 claude_cmd: %w[fake-claude], out: @out, clock: -> { @now },
                                 sleeper: ->(_) { }, idle_wait: 0, busy_wait: 0, version: "test", registry: registry,
                                 mailbox_home: File.join(@tmp, name, "mailbox"),
                                 claude_home: File.join(@tmp, name, "claude"), host: host)
  end

  def claude_for(name, **kw) = FakeClaude.new(File.join(@tmp, name, "claude"), **kw)

  def drive(disp, ticks: 300)
    ticks.times do
      disp.tick
      return if yield

      sleep 0.01
    end
    flunk "condition never held; log:\n#{@out.string}"
  end

  def owner_message!(soul: "avi") = agent_message!(soul: soul, person: @owner, content: "what is building?")
  def session_row = AgentDomainSession.find_by(domain: DOMAIN)
  def settled?(disp, message) = message.reload.status == "completed" && disp.runs.empty? && disp.chores.empty? &&
                                disp.leases.values.none?(&:busy)

  test "an owner message with the flag on runs a fresh session, then resumes it; each turn checkpoints" do
    claude = claude_for("mac")
    mac = machine("mac", claude: claude)

    first = owner_message!
    drive(mac) { settled?(mac, first) }
    row = session_row
    assert_equal [ "mac-worker", 1 ], [ row.holder, row.turns ]
    assert row.checkpoint.attached?, "the transcript was checkpointed"
    head = row.claude_session_id
    assert_match(/Answered\./, Zlib.gunzip(row.checkpoint.download))
    fresh = claude.all_calls.last
    assert_not_includes fresh[:argv], "--resume"
    assert_includes fresh[:stdin], "== PERSON:", "a fresh session's first turn is the whole prompt"
    assert_equal "fresh", first.reload.run_meta["warm"]

    second = owner_message!
    drive(mac) { settled?(mac, second) }
    resumed = claude.all_calls.last
    assert_equal [ "--resume", head ], resumed[:argv].last(2)
    assert_includes resumed[:stdin], "You are speaking with: owner", "every turn carries the board's audience"
    assert_includes resumed[:stdin], "UNTRUSTED DATA"
    assert_not_includes resumed[:stdin], "== PERSON:"
    assert_equal [ 2, second.reload.claude_session_id ], [ session_row.turns, session_row.claude_session_id ]
    assert_equal "resumed", second.run_meta["warm"]
    assert_equal "Answered.", second.response_text
    assert_not File.exist?(File.join(AgentMailbox::WarmSession.project_dir(File.join(@tmp, "mac", "mailbox", "avi"),
                                                                            claude_home: File.join(@tmp, "mac", "claude")),
                                     "#{head}.jsonl")), "the superseded transcript was pruned"
  end

  test "a client message and a released hold, with the flag on, stay one run per message, with no lease" do
    claude = claude_for("mac")
    mac = machine("mac", claude: claude)
    message = agent_message!(soul: "avi", person: @client_person, content: "how is my app?")
    drive(mac) { message.reload.status == "completed" && mac.runs.empty? }

    call = claude.all_calls.last
    assert_equal %w[fake-claude], call[:argv]
    assert_includes call[:stdin], "== PERSON:"
    assert_nil session_row, "no lease was ever taken"
    assert_nil message.reload.run_meta["warm"]

    released = agent_message!(soul: "avi", person: AgentPerson.create!(display_name: "Held", role: "team"),
                              content: "let me in", hold_released_at: Time.current, hold_released_by: "alex")
    drive(mac) { released.reload.status == "completed" && mac.runs.empty? }
    assert_equal %w[fake-claude], claude.all_calls.last[:argv], "a released hold is answered per message too"
    assert_nil session_row
  end

  test "with the flag off the dispatcher is today's: no lease, no resume, the full prompt" do
    claude = claude_for("mac")
    mac = machine("mac", claude: claude, registry: AgentMailbox::DomainRegistry.load)
    2.times do
      message = owner_message!
      drive(mac) { message.reload.status == "completed" && mac.runs.empty? }
      call = claude.all_calls.last
      assert_equal %w[fake-claude], call[:argv]
      assert_includes call[:stdin], "== PERSON:"
    end
    assert_equal 0, AgentDomainSession.count
  end

  test "the primary lapses: the standby takes the lease, restores the checkpoint and resumes it" do
    mac = machine("mac", claude: claude_for("mac"))
    first = owner_message!
    drive(mac) { settled?(mac, first) }
    head = session_row.claude_session_id

    work_claude = claude_for("work")
    work = machine("work", claude: work_claude)
    work.tick # its first ping makes its row
    AgentDispatcher.set_role!(host: "work", role: "standby", domains: [ DOMAIN ], registry: @warm)

    waiting = owner_message!
    3.times { work.tick }
    assert_equal "received", waiting.reload.status, "a standby claims nothing while the primary pings"

    travel AgentDomainSession::LEASE + 1.minute do
      @now += (AgentDomainSession::LEASE + 1.minute).to_i
      drive(work) { settled?(work, waiting) }
      row = session_row
      assert_equal [ "work-worker", 2 ], [ row.holder, row.turns ]
      call = work_claude.all_calls.last
      assert_equal [ "--resume", head ], call[:argv].last(2), "it resumed the primary's head"
      assert_match(/took the lapsed lease of mac-worker/, @out.string)
      assert_match(/restored the checkpoint of #{head}/, @out.string)

      late = assert_raises(AgentMailbox::ApiError) do
        @client.domain_checkpoint(DOMAIN, worker: "mac-worker", session_id: head, data: Zlib.gzip("x"), turns: 9,
                                          context_tokens: 1)
      end
      assert_equal [ 409, "NOT_HOLDER" ], [ late.status, late.code ], "the lapsed primary's late checkpoint is refused"
    end
  end

  test "handback happens only between turns, and the primary resumes the standby's head" do
    mac_claude = claude_for("mac")
    mac = machine("mac", claude: mac_claude)
    work_gate = Queue.new
    work_claude = claude_for("work", gate: work_gate)
    work = machine("work", claude: work_claude)
    work.tick
    AgentDispatcher.set_role!(host: "work", role: "standby", domains: [ DOMAIN ], registry: @warm)

    on_standby = owner_message!
    travel 1.minute do
      # No primary has ever pinged: the standby answers, and is mid-turn.
      @now += 61
      drive(work) { on_standby.reload.status == "claimed" && work.runs.any? }
      assert work.leases[DOMAIN].busy

      mac.tick # the primary pings: live again
      # A team member (another person: the owner's own next message would wait
      # for the first, the per-person order rule).
      asked = agent_message!(soul: "avi", person: AgentPerson.create!(display_name: "Teammate", role: "team"),
                             content: "status?")
      drive(mac) { asked.reload.status == "completed" && mac.runs.empty? }
      assert_equal %w[fake-claude], mac_claude.all_calls.last[:argv], "refused the lease: answered per message"
      assert session_row.handback_requested?
      @now += 61
      work.tick # the ping beat: mid-turn, so the lease is kept
      assert_equal "work-worker", session_row.holder, "never handed back mid-turn"

      work_gate << :go
      drive(work) { on_standby.reload.status == "completed" && work.runs.empty? && work.leases.empty? }
      row = session_row
      assert_nil row.holder, "released after its turn checkpointed"
      assert_equal 1, row.turns
      standby_head = row.claude_session_id

      back = owner_message!
      drive(mac) { settled?(mac, back) }
      assert_equal [ "--resume", standby_head ], mac_claude.all_calls.last[:argv].last(2)
      assert_equal "mac-worker", session_row.holder
      assert_match(/restored the checkpoint of #{standby_head}/, @out.string)
    end
  end

  test "past consolidate_at the holder writes a summary row and the next turn starts fresh from it" do
    claude = claude_for("mac", tokens: 60_000)
    mac = machine("mac", claude: claude)
    first = owner_message!
    drive(mac) { settled?(mac, first) && AgentDomainSummary.exists?(domain: DOMAIN) }

    summary = AgentDomainSummary.find_by!(domain: DOMAIN, generation: 1)
    assert_equal "Owner asked about the release.", summary.text
    assert_equal 1, summary.turns_covered
    row = session_row
    assert_equal [ 2, nil ], [ row.generation, row.claude_session_id ]
    summarize = claude.all_calls.last
    assert summarize[:stdin].start_with?("This session has grown long")
    assert_includes summarize[:argv], "--resume"

    second = owner_message!
    drive(mac) { settled?(mac, second) }
    call = claude.all_calls.first
    assert_not_includes call[:argv], "--resume", "a fresh session after consolidation"
    assert_includes call[:stdin], "== YOUR NOTES:"
    assert_includes call[:stdin], "Owner asked about the release."
  end
end
