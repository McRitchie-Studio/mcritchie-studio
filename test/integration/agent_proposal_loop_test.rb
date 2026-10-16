require "test_helper"
require_relative "../support/agent_message_fixtures"

# [integration] Propose, then confirm by reply, end to end with the SHIPPED
# config/agent_routes.yml and config/agent_domains.yml: a message arrives through
# the ingest the gateway and the poll share, the dispatcher's claim and complete
# go over the API with a PROPOSAL block in the answer, the reply posts with the
# confirm line (the Discord transport recorded, nothing leaves the test), and the
# owner's `go` in the thread runs it in code:
#   Avi proposes a change → go → a `designed` task bound to the thread, and the
#   thread is told "Opened `<slug>` <url>".
#   A non-owner's go → nothing.
#   Avi proposes release_status → go → the ladder posts, signed Avi; a go in
#   another thread and a top-level go leave a pending proposal alone.
#   Turf proposes an ask → go → the query runs and its answer posts, signed Turf.
#   With DISCORD_BOT_TOKEN_AVI set, Avi's answer posts once through his own bot,
#   unsigned; without it, through the shared bot, signed.
class AgentProposalLoopTest < ActionDispatch::IntegrationTest
  include AgentMessageFixtures
  include ActiveJob::TestHelper

  ALEX = AgentPerson::OWNER[:external_id]
  STRANGER = "777000000000000003".freeze
  GUILD_ID = "1332466565203103744".freeze
  CHANNEL = "1332466565203103999".freeze
  XAN_BOT = "1481150857809760399".freeze
  AVI_BOT = "1560516264378507334".freeze
  OTHER_CHANNEL = "1332466565203103998".freeze
  TURF_BOT = "1405042649479647293".freeze

  # A satellite's health endpoint, faked at the fetcher seam.
  class FakeFetcher
    attr_reader :calls

    def initialize = @calls = []

    def fetch(base_url, token:, ending:)
      @calls << [ base_url, ending ]
      { "schema" => 1, "sections" => [ { "key" => "signups", "count" => 4 }, { "key" => "errors", "count" => 2 } ],
        "error_groups" => [ { "error_class" => "NoMethodError", "message" => "secret-ish", "count" => 2 } ] }
    end
  end

  setup do
    AgentMessages::Answerers.current = AgentMessages::Answerers.load
    AgentProposal.reset_registry!
    AgentPerson.seed_owner!.set_role!("owner")
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @auth = { "Authorization" => "Bearer #{token}" }
    @posts = []
    @next_id = 990_000_000_000_000_000
    @previous_transport = AgentMessages::DiscordBot.transport
    @auths = []
    AgentMessages::DiscordBot.transport = lambda do |_method, _url, headers, body|
      @auths << headers["Authorization"]
      @posts << JSON.parse(body)
      [ 200, JSON.generate("id" => (@next_id += 1).to_s) ]
    end
  end

  teardown do
    AgentMessages::DiscordBot.transport = @previous_transport
    AgentProposals::Executor.fetcher = nil
  end

  def ingest(id, content, author: ALEX, users: [], reply_to: nil, channel: CHANNEL)
    raw = discord_raw(id, content: content, channel: channel, author: author, users: users, reply_to: reply_to,
                          guild: GUILD_ID)
    AgentMessages::DiscordIngest.new(routes: AgentMessages::Routes.load).call(raw, guild_id: GUILD_ID, source: "discord-gateway")
  end

  # What bin/dispatcher does: claim, read context, complete with the answer.
  def answer(soul, text)
    post claim_api_v1_agent_messages_url, params: { souls: [ soul ], worker: "mac-1" }, headers: @auth, as: :json
    data = response.parsed_body["data"]
    get context_api_v1_agent_message_url(data["id"]), params: { worker: "mac-1" }, headers: @auth
    catalog = response.parsed_body.dig("data", "proposals", "catalog").map { |c| c["capability"] }
    post complete_api_v1_agent_message_url(data["id"]), params: { worker: "mac-1", response_text: text },
                                                       headers: @auth, as: :json
    assert_response :success
    [ AgentMessage.find(data["id"]), catalog ]
  end

  CHANGE = <<~TEXT.freeze
    I can open a task for a footer theme toggle.
    ===PROPOSAL===
    {"kind": "change", "capability": "task", "summary": "Add a light/dark toggle to the footer",
     "params": {"title": "Footer Theme Toggle Added", "kind": "feature", "shape": "ui-only",
                "accept": ["The footer toggles between light and dark"], "test": ["[unit] the toggle renders"]}}
  TEXT

  test "Avi proposes a change, the owner says go, and a designed task is bound to the thread" do
    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      asked = ingest(4001, "<@#{AVI_BOT}> add a light/dark toggle to the footer", users: [ AVI_BOT ])
      assert_equal [ "received", "avi" ], [ asked.status, asked.soul_slug ]

      message, catalog = perform_enqueued_jobs { answer("avi", CHANGE) }
      assert_includes catalog, "task"
      assert_equal "**Avi** · I can open a task for a footer theme toggle.\n\n> Proposed: Add a light/dark toggle to " \
                   "the footer\n> Runs: change `task` · title Footer Theme Toggle Added · kind feature · shape ui-only · " \
                   "accept The footer toggles between light and dark · test [unit] the toggle renders\n" \
                   "#{AgentProposal::CONFIRM_LINE}", @posts.last["content"]
      refute_match(/PROPOSAL|"capability"/, @posts.last["content"])
      proposal = AgentProposal.sole
      reply_id = message.reload.reply_external_id

      # A stranger's go in the same thread: nothing runs and nothing posts.
      posts_before = @posts.size
      perform_enqueued_jobs { ingest(4002, "go", author: STRANGER, users: [ XAN_BOT ], reply_to: reply_id) }
      assert_equal posts_before, @posts.size
      assert_equal "proposed", proposal.reload.status
      assert_equal 0, Task.where(title: "Footer Theme Toggle Added").count

      go = perform_enqueued_jobs { ingest(4003, "go", users: [ XAN_BOT ], reply_to: reply_id) }
      task = Task.find_by!(title: "Footer Theme Toggle Added")
      assert_equal "designed", task.stage
      assert_equal "ui-only", task.metadata["devops"]["shape"]
      assert_equal [ "mcritchie-studio" ], task.metadata["devops"]["repositories"]
      assert_equal [ "The footer toggles between light and dark" ], task.metadata["devops"]["acceptance"]
      assert_equal message.discord_url, task.metadata["devops"]["source_thread"]
      assert_equal "executed", proposal.reload.status
      assert_equal task.slug, proposal.result["task_slug"]
      assert_equal "**Avi** · Opened `#{task.slug}` https://mcritchie.studio/tasks/#{task.slug}", @posts.last["content"]
      assert_equal go.external_id, @posts.last.dig("message_reference", "message_id"), "posted in reply to the go"
    end
  end

  test "Avi proposes release_status, the owner says go, and the ladder posts; a go elsewhere touches nothing" do
    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      Task.create!(title: "Reviewed Work Waits Here", stage: "designed").update_columns(stage: "reviewed")
      asked = ingest(6001, "<@#{AVI_BOT}> where is the release?", users: [ AVI_BOT ])
      assert_equal [ "received", "avi", "user" ], [ asked.status, asked.soul_slug, asked.routed_by ]

      text = "I can read the release ladder.\n===PROPOSAL===\n" \
             '{"kind": "ask", "capability": "release_status", "params": {}, "summary": "The release ladder now"}'
      message, catalog = perform_enqueued_jobs { answer("avi", text) }
      assert_equal %w[board_status recently_shipped release_status task], catalog
      assert_includes @posts.last["content"], "> Runs: ask `release_status` (no params)"
      proposal = AgentProposal.sole

      # A go in another channel's thread, and a top-level go to Avi: each starts
      # its own thread, so neither is a word on this proposal.
      perform_enqueued_jobs do
        elsewhere = ingest(6002, "<@#{AVI_BOT}> go", users: [ AVI_BOT ], channel: OTHER_CHANNEL)
        top = ingest(6003, "<@#{AVI_BOT}> go", users: [ AVI_BOT ])
        [ elsewhere, top ].each do |row|
          refute_equal message.thread_key, row.thread_key
          refute row.events.exists?(kind: "confirmed")
        end
      end
      assert_equal "proposed", proposal.reload.status, "a go outside the thread leaves the proposal pending"
      assert_nil proposal.confirm_message_id

      perform_enqueued_jobs { ingest(6004, "go", users: [ XAN_BOT ], reply_to: message.reload.reply_external_id) }
      assert_equal "executed", proposal.reload.status
      assert_match(/\A\*\*Avi\*\* · (Release now: `[^`]+`|No release is open\.).* Ladder: submitted \d+ · reviewed [1-9]\d* · assembled \d+\./,
                   @posts.last["content"])
    end
  end

  test "an owner message to Avi posts once through Avi's own bot, unsigned, when his token is set" do
    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      with_env("DISCORD_BOT_TOKEN_AVI", "avi-test-token") do
        asked = ingest(7001, "<@#{AVI_BOT}> what is building?", users: [ AVI_BOT ])
        assert_equal [ "received", "avi" ], [ asked.status, asked.soul_slug ]
        message, = perform_enqueued_jobs { answer("avi", "Two tasks are building.") }

        assert_equal [ "Bot avi-test-token" ], @auths, "one post, through Avi's bot"
        assert_equal "Two tasks are building.", @posts.sole["content"]
        assert_equal asked.external_id, @posts.sole.dig("message_reference", "message_id")
        assert_equal "posted", message.reload.reply_status
      end
    end
  end

  test "without Avi's own token the same message posts once through the shared bot, signed" do
    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      with_env("DISCORD_BOT_TOKEN_AVI", nil) do
        ingest(7101, "<@#{AVI_BOT}> what is building?", users: [ AVI_BOT ])
        message, = perform_enqueued_jobs { answer("avi", "Two tasks are building.") }

        assert_equal [ "Bot test-token" ], @auths
        assert_equal "**Avi** · Two tasks are building.", @posts.sole["content"]
        assert_equal "posted", message.reload.reply_status
      end
    end
  end

  test "Turf proposes an ask, the owner says go, and the query runs and answers" do
    fetcher = FakeFetcher.new
    with_env("DISCORD_AGENT_BOT_TOKEN", "test-token") do
      with_env("HEALTH_TOKEN_TURF_MONSTER", "test-health") do
        asked = ingest(5001, "<@#{TURF_BOT}> how many signups this week?", users: [ TURF_BOT ])
        assert_equal [ "received", "turf_monster", "user" ], [ asked.status, asked.soul_slug, asked.routed_by ]

        text = "I can pull that.\n===PROPOSAL===\n" \
               '{"kind": "ask", "capability": "signups_and_errors", "params": {"days": 7}, "summary": "Signups and errors, 7 days"}'
        message, catalog = perform_enqueued_jobs { answer("turf_monster", text) }
        assert_equal %w[signups_and_errors task], catalog
        assert @posts.last["content"].start_with?("**Turf** · I can pull that.")

        # Alex's reply pings the shared bot that posted Turf's answer; the thread keeps Turf.
        AgentProposals::Executor.fetcher = fetcher
        go = perform_enqueued_jobs { ingest(5002, "GO", users: [ XAN_BOT ], reply_to: message.reload.reply_external_id) }
        assert_equal "turf_monster", go.soul_slug
        assert_equal 7, fetcher.calls.size, "one daily window per day asked"
        assert_match(/\A\*\*Turf\*\* · Turf Monster, the 7 days to .*: 28 signups, 14 errors\. Most frequent: NoMethodError ×14\.\z/,
                     @posts.last["content"])
        refute_includes @posts.last["content"], "secret-ish", "error messages never reach the thread"
        assert_equal "executed", AgentProposal.sole.status
      end
    end
  end
end
