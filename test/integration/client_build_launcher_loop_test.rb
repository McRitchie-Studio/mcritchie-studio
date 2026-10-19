require "test_helper"
require "tmpdir"
require_relative "../support/client_cto_fixtures"
require_relative "../../bin/lib/client_build_launcher"

# [integration] bin/client-build-launcher's loop against the real board API
# (Api::V1::ClientBuildsController -> ClientBuilds), with the builder and the
# publish stubbed: a designed launch task is claimed, built in a scratch directory,
# published, and shipped, with the CTO chat lines posted; a failing builder blocks
# the task with the reason and the snag line; a dry run claims nothing; a stopped
# launcher puts its task back in line.
class ClientBuildLauncherLoopTest < ActionDispatch::IntegrationTest
  include ClientCtoFixtures
  include ActiveJob::TestHelper

  # AgentApi's seam (#token, #http_json, #invalidate_token!, #base_url), served by
  # this integration session instead of the network.
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
      headers = { "Authorization" => "Bearer #{bearer}" }
      @test.public_send(method, path, params: body, headers: headers, as: (body ? :json : nil))
      Response.new(@test.response.status.to_s, @test.response.body)
    end
  end

  Status = Struct.new(:ok) do
    def success? = ok
  end

  class StubPublisher
    attr_reader :calls

    def initialize(ok: true) = (@ok = ok) && (@calls = [])
    def available? = true
    def unavailable_reason = nil

    def call(subdomain, dir)
      @calls << [ subdomain, dir, File.read(File.join(dir, "index.html")) ]
      ClientBuildLauncher::Publisher::Result.new(ok: @ok, version: (@ok ? "v1" : nil), output: @ok ? "" : "upload refused")
    end
  end

  CONFIG = ClientBuildLauncher.config.merge("cap" => 2)

  setup do
    token = Rails.application.message_verifier("api_auth").generate("test", purpose: :api_auth, expires_in: 1.hour)
    @client = ClientBuildLauncher::Client.new(api: SessionApi.new(self, token))
    @root = Dir.mktmpdir("client-builds")
    @out = StringIO.new
    @prompts = []
  end

  teardown { FileUtils.rm_rf(@root) }

  def launch!(subdomain)
    request = AppRequest.create!(prompt: "A dog-walk scheduler", user: users(:viewer))
    AppLaunch.new(request, subdomain: subdomain, intake: client_intake).call!.task
  end

  def launcher(builder:, publisher: StubPublisher.new, dry_run: false)
    ClientBuildLauncher::Launcher.new(client: @client, config: CONFIG, worker: "test-mac", builder: builder, publisher: publisher,
                                      desk_bound: ->(_slug) { false }, root: @root, out: @out, dry_run: dry_run,
                                      sleeper: ->(_s) { })
  end

  def writing_builder
    lambda do |prompt, dir|
      @prompts << prompt
      html = File.read(File.join(dir, "index.html")).sub("</main>", "<section id=\"walks\">Walk schedule</section></main>")
      File.write(File.join(dir, "index.html"), html)
      ClientBuildLauncher::Sandbox::Result.new(status: :ok, exit_status: 0, turns: 3, summary: "Built it", stderr: "")
    end
  end

  def chat(sub) = AgentMessage.where(channel: "web", channel_ref: sub).where("envelope->>'via' = ?", ClientBuilds::VIA).order(:id)

  test "a designed launch task is claimed, built, published and shipped, with the chat lines" do
    task = launch!("dog-walks")
    publisher = StubPublisher.new
    launcher(builder: writing_builder, publisher: publisher).run(once: true)

    task.reload
    assert_equal "shipped", task.stage, @out.string
    assert_equal [ "preview_ready", "v1", "https://dog-walks.mcritchie.si" ],
                 task.devops["client_build"].values_at("state", "version", "preview_url")
    sub, dir, html = publisher.calls.sole
    assert_equal "dog-walks", sub
    assert dir.start_with?(File.join(@root, "dog-walks", "")), "a scratch directory per run, outside the repo"
    assert_includes html, "Walk schedule", "the builder's bundle is what publishes"
    assert_includes html, "data-site-footer"
    assert_includes @prompts.sole, "A dog-walk scheduler"
    assert_equal %w[started preview_ready], chat("dog-walks").map { |m| m.envelope["kind"] }
  end

  test "the launcher pings under its own soul, and its row never stands in for the mailbox dispatcher" do
    launcher(builder: writing_builder).tick

    row = AgentDispatcher.launchers.sole
    assert_equal [ "test-mac", [ ClientBuildLauncher::LAUNCHER_SOUL ], "running", 2 ], [ row.worker_id, row.souls, row.state, row.capacity ]
    assert_empty AgentDispatcher.primaries, "a launcher is not the mailbox's primary"
    assert AgentDispatcher.silent?, "a live launcher never hides a silent dispatcher"
  end

  test "a failing builder blocks the task with the reason and posts the snag line" do
    task = launch!("dog-walks")
    timing_out = ->(_prompt, _dir) { ClientBuildLauncher::Sandbox::Result.new(status: :timeout, exit_status: nil, turns: 9, stderr: "") }
    launcher(builder: timing_out).run(once: true)

    task.reload
    assert task.blocked?
    assert_includes task.devops.dig("client_build", "reason"), "45-minute cap"
    assert_equal %w[started failed], chat("dog-walks").map { |m| m.envelope["kind"] }
    assert_includes chat("dog-walks").last.response_text, "hit a snag"
  end

  test "a bundle that fails its check is never published" do
    task = launch!("dog-walks")
    publisher = StubPublisher.new
    inline = lambda do |_prompt, dir|
      File.write(File.join(dir, "index.html"), "<html><script>steal()</script></html>")
      ClientBuildLauncher::Sandbox::Result.new(status: :ok, exit_status: 0, turns: 1, stderr: "")
    end
    launcher(builder: inline, publisher: publisher).run(once: true)

    assert_empty publisher.calls
    assert task.reload.blocked?
    assert_includes task.devops.dig("client_build", "reason"), "inline <script>"
  end

  test "a dry run claims, builds and posts nothing" do
    task = launch!("dog-walks")
    built = false
    launcher(builder: ->(*) { built = true }, dry_run: true).run(once: true)

    assert_equal "designed", task.reload.stage
    refute built
    assert_empty chat("dog-walks")
    assert_includes @out.string, "would claim [\"#{task.slug}\"]"
  end

  test "the cap holds: two slots, three tasks, the oldest two claimed" do
    tasks = %w[app-one app-two app-three].map { |sub| launch!(sub).tap { travel 1.minute } }
    gate = Queue.new
    waiting = ->(_prompt, _dir) { gate.pop }
    loop_under_test = launcher(builder: waiting)
    loop_under_test.tick

    assert_equal tasks.first(2).map(&:slug).sort, loop_under_test.slots.map(&:slug).sort
    assert_equal %w[building building designed], tasks.map { |t| t.reload.stage }
    2.times { gate << ClientBuildLauncher::Sandbox::Result.new(status: :crashed, exit_status: 1, turns: 0, stderr: "x") }
    loop_under_test.drain
  end

  test "a stopped launcher puts its task back in line" do
    task = launch!("dog-walks")
    gate = Queue.new
    loop_under_test = launcher(builder: ->(*) { gate.pop })
    loop_under_test.tick
    loop_under_test.request_termination!
    loop_under_test.tick
    gate << ClientBuildLauncher::Sandbox::Result.new(status: :crashed, exit_status: nil, turns: 0, stderr: "")
    loop_under_test.drain

    task.reload
    assert_equal [ "designed", "released" ], [ task.stage, task.devops.dig("client_build", "state") ]
  end
end
