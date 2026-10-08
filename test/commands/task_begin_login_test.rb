require "test_helper"
require "open3"
require "tmpdir"
require "socket"
require "fileutils"
require "json"
require Rails.root.join("bin/lib/desk_session").to_s

# [integration] `bin/task begin` logs the desk's soul in to the task it claimed,
# keeps the session token inside the desk's git directory, and a later `bin/task`
# write to that task from inside the desk presents the session token. The same
# write from any other tree keeps the shared token (the control), so a reviewer
# on the same laptop never borrows the builder's login. Only the harness session
# that ran begin presents it: a reviewer running bin/task from inside the builder's
# desk keeps the shared token, so the board records the reviewer. A refused
# session drops and the write retries with the shared token, so no caller is
# locked out, and every later fallback write names the dropped session's slug.
#
# Against a local sink, never a board: TASK_API_BASE points at it.
class TaskBeginLoginTest < ActiveSupport::TestCase
  BIN = Rails.root.join("bin/task").to_s
  SLUG = "probe-task".freeze
  SHARED = "sink-bearer".freeze
  SESSION = "session-bearer".freeze
  BUILDER = "harness-builder".freeze
  REVIEWER = "harness-reviewer".freeze
  DROPPED = "X-Agent-Session-Dropped".freeze
  REVIEW = "review-bearer".freeze

  test "begin logs the builder in and keeps the token in the desk's git directory" do
    with_desk do |dir, desk, requests|
      _out, err, status = begin_task(dir, desk)

      assert status.success?, err
      login = requests.find { |r| r[:line].start_with?("POST /api/v1/agent_sessions") }
      assert login, "begin must POST the login: #{requests.map { |r| r[:line] }}"
      assert_equal "Bearer #{SHARED}", login[:auth], "the login is presented with the shared token"
      body = JSON.parse(login[:body])
      assert_equal ["pokemon", SLUG, "task_claim"], body.values_at("soul", "task_slug", "issued_by")

      assert_equal BUILDER, body["harness_session_id"]
      file = File.join(dir, "gitdir", "agent-session.json")
      assert_equal [SESSION, BUILDER], JSON.parse(File.read(file)).values_at("token", "harness_session_id")
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
      patches = requests.select { |r| r[:line].start_with?("PATCH") }
      assert_equal ["Bearer #{SESSION}", "Bearer #{SHARED}"], patches.map { |r| r[:auth] }
      assert_equal [nil, "sess-x"], patches.map { |r| r[:dropped] }, "the retry names the dropped session"
      assert_includes err, "agent session was refused (agent session sess-x was revoked)"
      file = File.join(dir, "gitdir", "agent-session.json")
      refute_includes File.read(file), SESSION, "the dropped session keeps no token"
    end
  end

  test "after the drop, every later write from the owner names the dropped session" do
    with_desk(refuse_session: true) do |dir, desk, requests|
      begin_task(dir, desk)
      task_from(desk, dir, "block", SLUG, "--kind", "rework")
      requests.clear

      _out, err, status = task_from(desk, dir, "block", SLUG, "--kind", "rework")

      assert status.success?, err
      patches = requests.select { |r| r[:line].start_with?("PATCH") }
      assert_equal [["Bearer #{SHARED}", "sess-x"]], patches.map { |r| [r[:auth], r[:dropped]] }
      refute_includes err, "was refused", "a dropped session is not re-presented"
    end
  end

  # The owner guard: a reviewer acting from the builder's desk is its own harness
  # session, so it keeps the shared token and the board records the reviewer it names.
  test "a reviewer's write from the builder's desk keeps the shared token and its own soul" do
    with_desk do |dir, desk, requests|
      begin_task(dir, desk)
      requests.clear

      _out, err, status = task_from(desk, dir, "block", SLUG, "--kind", "rework", "--agent", "carl",
                                    "--feedback", "needs a test", harness: REVIEWER)

      assert status.success?, err
      write = requests.find { |r| r[:line].start_with?("PATCH /api/v1/tasks/#{SLUG}/block") }
      assert_equal "Bearer #{SHARED}", write&.dig(:auth), requests.inspect
      assert_nil write[:dropped], "a reviewer's write names no desk session"
      assert_equal "carl", JSON.parse(write[:body])["by"]
      note = requests.find { |r| r[:line].start_with?("POST /api/v1/activities") }
      assert_equal "Bearer #{SHARED}", note&.dig(:auth), requests.inspect
    end
  end

  test "a reviewer-run bin/task note from the builder's desk records the reviewer" do
    with_desk do |dir, desk, requests|
      begin_task(dir, desk)
      requests.clear

      _out, err, status = task_from(desk, dir, "note", SLUG, "--comment", "reviewed", "--agent", "carl",
                                    harness: REVIEWER)

      assert status.success?, err
      note = requests.find { |r| r[:line].start_with?("POST /api/v1/activities") }
      assert_equal "Bearer #{SHARED}", note&.dig(:auth), requests.inspect
      assert_equal "carl", JSON.parse(note[:body])["agent_slug"]
    end
  end

  # The guard's other edge: a run that names no harness session cannot prove it is
  # the owner, so it keeps the shared token too.
  test "a run naming no harness session keeps the shared token from the desk" do
    with_desk do |dir, desk, requests|
      begin_task(dir, desk)
      requests.clear

      task_from(desk, dir, "block", SLUG, "--kind", "rework", harness: nil)

      write = requests.find { |r| r[:line].start_with?("PATCH /api/v1/tasks/#{SLUG}/block") }
      assert_equal "Bearer #{SHARED}", write&.dig(:auth), requests.inspect
    end
  end

  test "begin --agent prints that soul's dream sequence to stderr" do
    with_desk do |dir, _desk, _requests|
      out, err, status = Open3.capture3(env(dir).merge("TASK_BEGIN_PROJECTS_DIR" => dir), BIN, "begin", SLUG,
                                        "--agent", "carl", chdir: dir)

      assert status.success?, err
      assert_includes err, "## Carl's dream sequence · task #{SLUG}"
      refute_includes out, "dream sequence"
    end
  end

  # ---- the review claim's login (DeskSession.write_review) ------------------------

  test "a reviewer's write presents its review login, and the builder's keeps the desk's" do
    with_desk do |dir, desk, requests|
      begin_task(dir, desk)
      keep_review_login(desk)
      requests.clear

      task_from(desk, dir, "block", SLUG, "--kind", "rework", "--agent", "carl", "--feedback", "needs a test",
                harness: REVIEWER)
      task_from(desk, dir, "update", SLUG, "--local-url", "http://localhost:3018/", harness: BUILDER)

      writes = requests.select { |r| r[:line].start_with?("PATCH /api/v1/tasks/#{SLUG}") }
      assert_equal ["Bearer #{REVIEW}", "Bearer #{SESSION}"], writes.map { |r| r[:auth] }, requests.inspect
    end
  end

  test "a refused review login is forgotten and the write retries with the shared token" do
    with_desk(refuse_session: REVIEW) do |dir, desk, requests|
      begin_task(dir, desk)
      file = keep_review_login(desk)
      requests.clear

      _out, err, status = task_from(desk, dir, "block", SLUG, "--kind", "rework", harness: REVIEWER)

      assert status.success?, err
      patches = requests.select { |r| r[:line].start_with?("PATCH") }
      assert_equal ["Bearer #{REVIEW}", "Bearer #{SHARED}"], patches.map { |r| r[:auth] }
      refute File.exist?(file), "the refused review login is deleted"
      refute_includes err, REVIEW, "the token is never printed"
      desk_file = File.join(dir, "gitdir", "agent-session.json")
      assert_includes File.read(desk_file), SESSION, "the builder's login is untouched"
    end
  end

  private

  def keep_review_login(desk)
    DeskSession.write_review(desk, { "slug" => "sess-r", "soul" => "carl", "task_slug" => SLUG, "token" => REVIEW,
                                     "expires_at" => (Time.now + 3600).utc.iso8601,
                                     "harness_session_id" => REVIEWER })
  end

  def begin_task(dir, desk)
    Open3.capture3(env(dir).merge("TASK_BEGIN_PROJECTS_DIR" => dir), BIN, "begin", SLUG, "--agent", "pokemon",
                   chdir: dir)
  ensure
    FileUtils.mkdir_p(desk)
  end

  def task_from(cwd, dir, *args, harness: BUILDER)
    Open3.capture3(env(dir, harness: harness), BIN, *args, chdir: cwd)
  end

  # Every run is a harness session: begin and the builder's writes are BUILDER.
  # A harness id makes bin/task read usage, so the usage stores are pinned in the tmpdir.
  def env(dir, harness: BUILDER)
    TaskUsageSandboxEnv.child_env(dir).merge(
      "TASK_API_BASE" => @base, "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
      "AGENT_API_TOKEN" => nil, "CLAUDE_CODE_SESSION_ID" => harness, "CLAUDE_SESSION_ID" => nil,
      "CODEX_THREAD_ID" => nil,
      "TASK_BEGIN_MOVE_BIN" => File.join(dir, "move-stub"),
      "TASK_BEGIN_WORKTREE_BIN" => File.join(dir, "worktree-stub"),
      "TASK_BEGIN_PREFLIGHT_BIN" => File.join(dir, "preflight-stub")
    )
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
        dropped = nil
        length = 0
        while (header = client.gets) && header.strip != ""
          length = Regexp.last_match(1).to_i if header =~ /^Content-Length:\s*(\d+)/i
          auth = header.split(":", 2).last.strip if header =~ /^Authorization:/i
          dropped = header.split(":", 2).last.strip if header =~ /^#{DROPPED}:/i
        end
        body = length.positive? ? client.read(length) : nil
        requests << { line: line, auth: auth, body: body, dropped: dropped }
        status, reply =
          if line.include?("/api/v1/auth") then [200, { token: SHARED }.to_json]
          elsif line.start_with?("POST /api/v1/agent_sessions") then [201, session]
          elsif line.start_with?("POST /api/v1/activities") then [201, { data: { slug: "activity-1" } }.to_json]
          elsif line.include?("/api/v1/activities") then [200, { data: [] }.to_json]
          elsif refuse_session && auth == "Bearer #{refuse_session == true ? SESSION : refuse_session}"
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
