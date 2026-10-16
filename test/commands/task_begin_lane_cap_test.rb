require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "fileutils"
require "json"

# [integration] `bin/task begin` asks the board for the app's free building lane
# BEFORE it cuts a desk (docs/agents/system/client-pipeline.md): a refusal stops it
# with the board's message, no worktree step and no claim; no refusal, or a board
# without the endpoint (404), lets begin proceed to the claim, whose validation is
# the authority. Against a local sink, never a board.
class TaskBeginLaneCapTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "lane-probe".freeze
  REFUSAL = "Turf Monster is on the Vibe tier: 1 of 1 building lane in use (other-task). This task waits in designed " \
            "until one is submitted; or upgrade to Builder for 2 lanes (/packages).".freeze

  test "a refusal stops begin before the desk: no worktree, no claim" do
    with_sink(lane: [ 200, { data: { slug: SLUG, refusal: REFUSAL } } ]) do |dir, requests|
      _out, err, status = run_begin(dir)

      refute status.success?
      assert_includes err, "lane cap: #{REFUSAL}"
      assert_includes err, "no desk was cut"
      refute File.exist?(File.join(dir, "worktree-ran")), "the worktree step never ran"
      refute File.exist?(File.join(dir, "move-ran")), "the claim never ran"
      assert requests.any? { |line| line.start_with?("GET /api/v1/tasks/#{SLUG}/building_lane") }
    end
  end

  test "no refusal, or a board without the endpoint, lets begin cut the desk and claim" do
    [ [ 200, { data: { slug: SLUG, refusal: nil } } ], [ 404, { error: "Not found" } ] ].each do |lane|
      with_sink(lane: lane) do |dir, _requests|
        _out, err, status = run_begin(dir)

        assert status.success?, "#{lane.first}: #{err}"
        assert File.exist?(File.join(dir, "worktree-ran")), "#{lane.first}: the worktree step ran"
        assert File.exist?(File.join(dir, "move-ran")), "#{lane.first}: the claim ran"
      end
    end
  end

  private

  def run_begin(dir)
    env = TaskUsageSandboxEnv.child_env(dir).merge(
      "TASK_API_BASE" => @base, "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
      "AGENT_API_TOKEN" => nil, "CLAUDE_CODE_SESSION_ID" => nil, "CLAUDE_SESSION_ID" => nil, "CODEX_THREAD_ID" => nil,
      "TASK_BEGIN_PROJECTS_DIR" => dir, "DREAM_BANK_DIR" => File.join(dir, "no-bank"),
      "TASK_BEGIN_MOVE_BIN" => File.join(dir, "move-stub"),
      "TASK_BEGIN_WORKTREE_BIN" => File.join(dir, "worktree-stub"),
      "TASK_BEGIN_PREFLIGHT_BIN" => File.join(dir, "preflight-stub")
    )
    Open3.capture3(env, BIN, "begin", SLUG, "--agent", "pokemon", chdir: dir)
  end

  def with_sink(lane:)
    Dir.mktmpdir do |dir|
      desk = File.join(dir, "turf-monster", ".worktrees", SLUG)
      FileUtils.mkdir_p(desk)
      FileUtils.mkdir_p(File.join(dir, "gitdir"))
      File.write(File.join(desk, ".git"), "gitdir: #{File.join(dir, "gitdir")}\n")
      { "move-stub" => "move-ran", "worktree-stub" => "worktree-ran", "preflight-stub" => nil }.each do |name, marker|
        path = File.join(dir, name)
        File.write(path, "#!/bin/sh\n#{marker ? "touch #{File.join(dir, marker)}\n" : ''}exit 0\n")
        FileUtils.chmod(0o755, path)
      end
      task = { data: { slug: SLUG, stage: "designed", title: "Lane Probe",
                       metadata: { devops: { worktree_slug: SLUG, repositories: [ "turf-monster" ], built_by: "pokemon" } } } }.to_json
      requests = []
      server = TCPServer.new("127.0.0.1", 0)
      thread = Thread.new do
        while (client = server.accept)
          line = client.gets.to_s
          length = 0
          while (header = client.gets) && header.strip != ""
            length = Regexp.last_match(1).to_i if header =~ /^Content-Length:\s*(\d+)/i
          end
          client.read(length) if length.positive?
          requests << line
          status, reply =
            if line.include?("/api/v1/auth") then [ 200, { token: "sink-bearer" }.to_json ]
            elsif line.include?("/building_lane") then [ lane.first, lane.last.to_json ]
            elsif line.start_with?("POST /api/v1/agent_sessions") then [ 422, { error: "no" }.to_json ]
            elsif line.include?("/api/v1/activities") then [ 200, { data: [] }.to_json ]
            else [ 200, task ]
            end
          client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\n\r\n#{reply}")
          client.close
        end
      rescue IOError, Errno::EBADF
        nil
      end
      @base = "http://127.0.0.1:#{server.addr[1]}"
      yield dir, requests
    ensure
      server&.close
      thread&.kill
    end
  end
end
