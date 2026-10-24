require "test_helper"
require "tmpdir"
require_relative "../../bin/lib/client_build_launcher"

# [integration] bin/client-build-launcher's loop starting a chat-sourced change
# card against the real board API (Api::V1::ChangeBuildsController ->
# ChangeBuilds), with bin/task begin stubbed: the card the owner confirmed in the
# Turf web chat is claimed, begin runs, the card reaches building, its thread gets
# one "Building started" line and the card carries the builder launch line. A
# refused begin leaves the card designed with the reason. Controls: an unconfirmed
# card and a full cap start nothing; a dry run starts nothing.
class ChangeBuildLauncherLoopTest < ActionDispatch::IntegrationTest
  class SessionApi
    Response = Struct.new(:code, :body)

    def initialize(test, token)
      @test = test
      @token = token
    end

    def base_url = "http://www.example.com"
    def token = @token
    def invalidate_token! = nil

    def http_json(method, path, body, bearer:)
      @test.public_send(method, path, params: body, headers: { "Authorization" => "Bearer #{bearer}" }, as: (body ? :json : nil))
      Response.new(@test.response.status.to_s, @test.response.body)
    end
  end

  class IdlePublisher
    def available? = true
    def unavailable_reason = nil
  end

  Status = Struct.new(:code) do
    def success? = code.zero?
    def exitstatus = code
  end

  # Stands in for `bin/task begin <slug> --agent pokemon`: on success it moves the
  # card to building as begin's claim does and prints begin's worktree line.
  class StubBegin
    attr_reader :calls

    def initialize(ok: true)
      @ok = ok
      @calls = []
    end

    def call(argv, chdir:, timeout:)
      @calls << argv
      slug = argv[2]
      return [ "begin 2/5 worktree — no free port in 3100-3199\n", Status.new(1) ] unless @ok

      Task.find_by!(slug: slug).update!(stage: "building")
      [ "turf-monster · #{slug} · https://mcritchie.studio/tasks/#{slug}\nworktree: /Users/alex/projects/turf-monster/.worktrees/#{slug}\n",
        Status.new(0) ]
    end
  end

  setup do
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = ClientBuildLauncher::Client.new(api: SessionApi.new(self, token))
    @root = Dir.mktmpdir("change-builds")
    @out = StringIO.new
  end

  teardown { FileUtils.rm_rf(@root) }

  def chat_card!(slug, status: "executed")
    task = Task.create!(title: "Dark toggle", slug: slug, stage: "designed", priority: 1,
                        metadata: { "devops" => { "kind" => "feature", "shape" => "ui-only", "repositories" => [ "turf-monster" ],
                                                  "acceptance" => [ "a toggle" ],
                                                  "source_thread" => "#{AgentProposal::BOARD_URL}/applications/turf-monster/chat" } })
    ask = AgentMessage.create!(channel: "web", external_id: "web-#{slug}", channel_ref: "turf-monster",
                               thread_key: AgentMessages::WebChat.thread_key("turf-monster", 7), author_ref: "7",
                               author_name: "Owner", content: "add a dark toggle", soul_slug: "turf_monster",
                               routed_by: "chat", status: "completed")
    AgentProposal.create!(thread_key: ask.thread_key, channel: "web", channel_ref: "turf-monster", soul_slug: "turf_monster",
                          source_message: ask, kind: "change", capability: "task", params: { "title" => "Dark toggle" },
                          summary: "Open a task", status: status, settled_by: (status == "proposed" ? nil : "web:7"),
                          expires_at: 1.day.from_now, result: (status == "executed" ? { "task_slug" => slug } : {}))
    task
  end

  def launcher(starter, config: ClientBuildLauncher.config.merge("cap" => 2), dry_run: false)
    ClientBuildLauncher::Launcher.new(client: @client, config: config, worker: "test-mac", builder: ->(_p, _d) { raise "no build" },
                                      publisher: IdlePublisher.new, desk_bound: ->(_slug) { false }, root: @root, out: @out,
                                      dry_run: dry_run, sleeper: ->(_s) { },
                                      change_start: ClientBuildLauncher::ChangeStart.new(task_bin: "/fixed/bin/task", runner: starter))
  end

  test "[integration] a chat-sourced change card reaches building in the launcher's loop, with one message back" do
    card = chat_card!("dark-toggle")
    starter = StubBegin.new

    launcher(starter).run(once: true)

    assert_equal [ [ "/fixed/bin/task", "begin", "dark-toggle", "--agent", "pokemon" ] ], starter.calls
    card.reload
    assert_equal "building", card.stage
    run = ChangeBuilds.run_of(card)
    assert_equal [ "started", "/Users/alex/projects/turf-monster/.worktrees/dark-toggle" ], run.values_at("state", "desk")
    assert_includes run["launch_line"], "claude --agent pokemon"
    lines = AgentMessage.where(external_id: "change-build:dark-toggle:started")
    assert_equal [ "Building started, task `dark-toggle`." ], lines.pluck(:response_text)
    assert_match(/dark-toggle: building; desk/, @out.string)

    # Control: the next pass finds nothing to start and posts nothing more.
    launcher(starter).run(once: true)
    assert_equal 1, starter.calls.size
    assert_equal 1, AgentMessage.where(external_id: "change-build:dark-toggle:started").count
  end

  test "[integration] a refused begin leaves the card designed with the reason and no thread message" do
    card = chat_card!("no-slot")

    launcher(StubBegin.new(ok: false)).run(once: true)

    card.reload
    assert_equal "designed", card.stage
    assert_equal "refused", ChangeBuilds.run_of(card)["state"]
    assert_match(/bin\/task begin exited 1: begin 2\/5 worktree — no free port/, ChangeBuilds.run_of(card)["refused_reason"])
    assert_equal 0, AgentMessage.where(external_id: "change-build:no-slot:started").count
  end

  test "[integration] controls: an unconfirmed card, a full cap and a dry run start nothing" do
    chat_card!("still-proposed", status: "proposed")
    starter = StubBegin.new
    launcher(starter).run(once: true)
    assert_empty starter.calls

    chat_card!("confirmed-card")
    full = launcher(starter)
    full.slots << ClientBuildLauncher::Launcher::Slot.new(slug: "busy", run_id: "r", thread: Thread.new { })
    full.slots << ClientBuildLauncher::Launcher::Slot.new(slug: "busy-2", run_id: "r", thread: Thread.new { })
    full.start_changes
    assert_empty starter.calls, "a launcher at its cap starts no change card"

    launcher(starter, dry_run: true).run(once: true)
    assert_empty starter.calls
    assert_match(/would start \["confirmed-card"\]; started nothing/, @out.string)
    assert_equal "designed", Task.find_by!(slug: "confirmed-card").stage
  end
end
