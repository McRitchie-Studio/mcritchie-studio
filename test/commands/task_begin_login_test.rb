require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "fileutils"
require "json"

# [integration] `bin/task begin` logs the desk's soul in to the task it claimed,
# keeps the session token inside the desk's git directory, and a later `bin/task`
# write to that task from inside the desk presents the session token. The same
# write from any other tree keeps the shared token (the control), so a reviewer
# on the same laptop never borrows the builder's login. A refused session drops
# and the write retries with the shared token, so no caller is locked out.
#
# Against a local sink, never a board: TASK_API_BASE points at it.
class TaskBeginLoginTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "probe-task".freeze
  SHARED = "sink-bearer".freeze
  SESSION = "session-bearer".freeze

  test "begin logs the builder in and keeps the token in the desk's git directory" do
    with_desk do |dir, desk, requests|
      _out, err, status = begin_task(dir, desk)

      assert status.success?, err
      login = requests.find { |r| r[:line].start_with?("POST /api/v1/agent_sessions") }
      assert login, "begin must POST the login: #{requests.map { |r| r[:line] }}"
      assert_equal "Bearer #{SHARED}", login[:auth], "the login is presented with the shared token"
      body = JSON.parse(login[:body])
      assert_equal ["pokemon", SLUG, "task_claim"], body.values_at("soul", "task_slug", "issued_by")

      file = File.join(dir, "gitdir", "agent-session.json")
      assert_equal SESSION, JSON.parse(File.read(file))["token"]
      assert_equal 0o600, File.stat(file).mode & 0o777
      refute File.exist?(File.join(desk, "agent-session.json")), "the token never lands in the working tree"
      refute_includes err, SESSION, "the token is never printed"
    end
  end

  test "a write to the task from inside the desk presents the session token" do
    with_desk do |dir, desk, requests|
      begin_task(dir, desk)
      requests.clear

      _out, err, status = task_from(desk, dir, "block", SLUG, "--kind", "rework")

      assert status.success?, err
      write = requests.find { |r| r[:line].start_with?("PATCH /api/v1/tasks/#{SLUG}/block") }
      assert_equal "Bearer #{SESSION}", write&.dig(:auth), requests.inspect
    end
  end

  # The control: the identical write from a tree that is not the desk keeps the
  # shared token, so the test above is the desk's login at work.
  test "the same write from another tree keeps the shared token" do
    with_desk do |dir, desk, requests|
      begin_task(dir, desk)
      requests.clear
      elsewhere = File.join(dir, "elsewhere")
      FileUtils.mkdir_p(File.join(elsewhere, ".git"))

      task_from(elsewhere, dir, "block", SLUG, "--kind", "rework")

      write = requests.find { |r| r[:line].start_with?("PATCH /api/v1/tasks/#{SLUG}/block") }
      assert_equal "Bearer #{SHARED}", write&.dig(:auth), requests.inspect
    end
  end

  test "a refused session is dropped and the write retries with the shared token" do
    with_desk(refuse_session: true) do |dir, desk, requests|
      begin_task(dir, desk)
      requests.clear

      _out, err, status = task_from(desk, dir, "block", SLUG, "--kind", "rework")

      assert status.success?, err
      auths = requests.select { |r| r[:line].start_with?("PATCH") }.map { |r| r[:auth] }
      assert_equal ["Bearer #{SESSION}", "Bearer #{SHARED}"], auths
      assert_includes err, "agent session was refused (agent session sess-x was revoked)"
      refute File.exist?(File.join(dir, "gitdir", "agent-session.json"))
    end
  end

  private

  def begin_task(dir, desk)
    Open3.capture3(env(dir).merge("TASK_BEGIN_PROJECTS_DIR" => dir), BIN, "begin", SLUG, "--agent", "pokemon",
                   chdir: dir)
  ensure
    FileUtils.mkdir_p(desk)
  end

  def task_from(cwd, dir, *args)
    Open3.capture3(env(dir), BIN, *args, chdir: cwd)
  end

  def env(dir)
    { "TASK_API_BASE" => @base, "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
      "AGENT_API_TOKEN" => nil, "CLAUDE_CODE_SESSION_ID" => nil, "CLAUDE_SESSION_ID" => nil,
      "TASK_BEGIN_MOVE_BIN" => File.join(dir, "move-stub"),
      "TASK_BEGIN_WORKTREE_BIN" => File.join(dir, "worktree-stub"),
      "TASK_BEGIN_PREFLIGHT_BIN" => File.join(dir, "preflight-stub") }
  end

  # A temp projects dir with the desk begin will find, its `.git` pointer file
  # (as a real worktree has), stubbed worktree/preflight/move steps, and a sink.
  def with_desk(refuse_session: false)
    Dir.mktmpdir do |dir|
      desk = File.join(dir, "mcritchie-studio", ".worktrees", SLUG)
      FileUtils.mkdir_p(desk)
      FileUtils.mkdir_p(File.join(dir, "gitdir"))
      File.write(File.join(desk, ".git"), "gitdir: #{File.join(dir, "gitdir")}\n")
      %w[move-stub worktree-stub preflight-stub].each do |name|
        path = File.join(dir, name)
        File.write(path, "#!/bin/sh\nexit 0\n")
        FileUtils.chmod(0o755, path)
      end
      requests = []
      with_sink(requests, refuse_session: refuse_session) do |base|
        @base = base
        yield dir, desk, requests
      end
    end
  end

  def with_sink(requests, refuse_session:)
    server = TCPServer.new("127.0.0.1", 0)
    task = { data: { slug: SLUG, stage: "designed", title: "Probe Task",
                     metadata: { devops: { worktree_slug: SLUG, repositories: ["mcritchie-studio"],
                                           built_by: "pokemon" } } } }.to_json
    session = { data: { slug: "sess-x", soul: "pokemon", tier: "studio", task_slug: SLUG,
                        expires_at: (Time.now + 3600).utc.iso8601, token: SESSION } }.to_json
    thread = Thread.new do
      while (client = server.accept)
        line = client.gets.to_s
        auth = nil
        length = 0
        while (header = client.gets) && header.strip != ""
          length = Regexp.last_match(1).to_i if header =~ /^Content-Length:\s*(\d+)/i
          auth = header.split(":", 2).last.strip if header =~ /^Authorization:/i
        end
        body = length.positive? ? client.read(length) : nil
        requests << { line: line, auth: auth, body: body }
        status, reply =
          if line.include?("/api/v1/auth") then [200, { token: SHARED }.to_json]
          elsif line.start_with?("POST /api/v1/agent_sessions") then [201, session]
          elsif line.include?("/api/v1/activities") then [200, { data: [] }.to_json]
          elsif refuse_session && auth == "Bearer #{SESSION}"
            [401, { error: "agent session sess-x was revoked", error_code: "SESSION_ENDED" }.to_json]
          else [200, task]
          end
        client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{reply.bytesize}\r\n\r\n#{reply}")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}"
  ensure
    server&.close
    thread&.kill
  end
end
