require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require_relative "../support/desk_ledger_sink"

# GEM REPOS GET DESKS (gem-repos-get-desks).
#
# THE DEFECT. `bin/agent-worktree new` resolved its app through the satellite
# registry alone, so studio-engine and solana-studio, which are gems and not apps,
# answered "unknown app" and engine builders cut their desks by hand with
# `git worktree add`. A hand-cut desk carried no context marker, no task binding and
# no identity stamp, and `bin/task begin --repo studio-engine` died at step 2.
#
# THE LANE. A repo config/release_repos.yml files under `gems:` now gets a desk from
# `new` and a binding from `bind-task`, with no port, Redis slot or database: those
# are app things. Everything here runs the REAL script against throwaway repos in a
# tmpdir, each with a real bare origin, so `new` cuts from origin/accepted exactly as
# it does on the operator's machine.
class AgentWorktreeGemDeskTest < ActiveSupport::TestCase
  TASK = "gem-lane-desk".freeze
  WORKTREE_BIN = Rails.root.join("bin/agent-worktree").to_s
  TASK_BIN = Rails.root.join("bin/task").to_s

  def setup
    @projects_dir = File.realpath(Dir.mktmpdir("agent-worktree-gem-desk"))
    @desk_ledger = DeskLedgerSink.start
    init_hub
  end

  def teardown
    @desk_ledger&.stop
    FileUtils.rm_rf(@projects_dir) if @projects_dir
  end

  %w[studio-engine solana-studio].each do |gem_slug|
    test "[unit] new cuts a #{gem_slug} desk with no port, Redis slot or database" do
      repo = init_gem_repo(gem_slug)
      desk = File.join(repo, ".worktrees", TASK)

      out, err, status = agent_worktree("new", gem_slug, TASK)

      assert status.success?, "#{out}\n#{err}"
      refute_includes err, "unknown app"
      assert Dir.exist?(desk), "the desk is cut at <repo>/.worktrees/<task>"
      assert_equal "feat/#{TASK}", git_out(desk, "rev-parse", "--abbrev-ref", "HEAD")
      assert_equal git_out(repo, "rev-parse", "origin/accepted"), git_out(desk, "rev-parse", "HEAD"),
                   "a gem desk is cut from origin/accepted, like every other desk"
      assert_includes out, "port:     none"
      assert_includes out, "test:     bin/release-check"

      env = File.read(File.join(desk, ".env.agent-stack"))
      assert_includes env, "APP_SLUG=#{gem_slug}"
      %w[APP_PORT= PORT= REDIS_URL= DATABASE_URL= TM_REDIS_DB=].each do |key|
        refute_match(/^#{key}/, env, "a gem desk allocates no #{key.chomp("=")}")
      end
      refute File.exist?(File.join(desk, ".env.development.local")), "no database pointer for a gem desk"
      refute File.exist?(File.join(desk, ".env.test.local")), "no test database is provisioned"

      context = JSON.parse(File.read(File.join(desk, ".agent-context.json")))
      assert_equal gem_slug, context.fetch("app")
      assert_nil context.fetch("app_port")
      assert_nil context.fetch("local_url")
      assert_nil context.fetch("redis_db")
      assert_nil context.fetch("database")

      assert_empty git_out(desk, "status", "--porcelain"),
                   "the generated stack env and context marker must not read as work bin/submit would commit"
    end
  end

  test "[unit] new --soul stamps the gem desk's own identity" do
    init_gem_repo("studio-engine")
    desk = File.join(@projects_dir, "studio-engine", ".worktrees", TASK)

    out, err, status = agent_worktree("new", "studio-engine", TASK, "--soul", "carl")

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "identity: Carl <carl@mcritchie.studio>"
    assert_equal "Carl <carl@mcritchie.studio>", git_out(desk, "var", "GIT_AUTHOR_IDENT").sub(/\s+\d+\s+[-+]\d{4}\z/, "")
  end

  test "[unit] new over an existing gem desk is a resume that keeps its binding" do
    init_gem_repo("studio-engine")
    desk = File.join(@projects_dir, "studio-engine", ".worktrees", TASK)
    agent_worktree!("new", "studio-engine", TASK)
    agent_worktree!("bind-task", "studio-engine", TASK, "gem-task")

    agent_worktree!("new", "studio-engine", TASK)

    env = File.read(File.join(desk, ".env.agent-stack"))
    assert_includes env, "TASK_RECORD_SLUG=gem-task"
    refute_match(/^APP_PORT=/, env, "a resume allocates nothing either")
  end

  test "[unit] bind-task records the task on a gem desk" do
    init_gem_repo("solana-studio")
    desk = File.join(@projects_dir, "solana-studio", ".worktrees", TASK)
    agent_worktree!("new", "solana-studio", TASK)

    out, err, status = agent_worktree("bind-task", "solana-studio", TASK, "gem-task")

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "task url: https://mcritchie.studio/tasks/gem-task"
    context = JSON.parse(File.read(File.join(desk, ".agent-context.json")))
    assert_equal "gem-task", context.fetch("task_record_slug")
    assert_nil context.fetch("app_port")
  end

  test "[unit] a stack command on a gem repo names the gem lane, not unknown app" do
    init_gem_repo("studio-engine")
    agent_worktree!("new", "studio-engine", TASK)

    out, err, status = agent_worktree("up", "studio-engine", TASK)

    refute status.success?, "a gem desk has no server to start:\n#{out}"
    refute_includes err, "unknown app"
    assert_includes err, "studio-engine is a gem repo"
    assert_includes err, "Run its suite in the desk: bin/release-check"
  end

  test "[unit] a missing gem desk's identity remedy is new, which now cuts it" do
    init_gem_repo("studio-engine")

    _out, err, status = agent_worktree("identity", "studio-engine", TASK, "carl")

    refute status.success?
    assert_includes err, "agent-worktree new studio-engine #{TASK} --soul carl"
    refute_includes err, "worktree add"
  end

  # The control: a repo with desks that release_repos.yml does NOT file as a gem
  # (turf-vault is an `apps` row there) keeps refusing, so the lane is the
  # registry's declaration and not "any repo on disk".
  test "[unit] a repo the registry does not call a gem still answers unknown app" do
    init_gem_repo("turf-vault")

    _out, err, status = agent_worktree("new", "turf-vault", TASK)

    refute status.success?
    assert_includes err, "unknown app: turf-vault"
    refute Dir.exist?(File.join(@projects_dir, "turf-vault", ".worktrees", TASK))
  end

  # Registered apps keep their behaviour: a resumed hub desk still carries its port,
  # Redis slot and database, and is not mistaken for a gem.
  test "[unit] a registered app's desk keeps its port, Redis slot and database" do
    hub_desk = File.join(@projects_dir, "mcritchie-studio", ".worktrees", TASK)
    git_out(File.join(@projects_dir, "mcritchie-studio"), "worktree", "add", "-q", hub_desk, "-b", "feat/#{TASK}")
    File.write(File.join(hub_desk, ".env.agent-stack"), <<~ENVFILE)
      AGENT_WORKTREE=1
      APP_SLUG=mcritchie-studio
      TASK_SLUG=#{TASK}
      APP_PORT=39997
      PORT=39997
      REDIS_URL=redis://localhost:63999/9
      DATABASE_URL=postgresql://localhost/mcritchie_studio_development_gem_lane_probe
      MCRITCHIE_SESSION_KEY=_studio_session_gem_lane_desk
    ENVFILE

    out, err, status = agent_worktree("bind-task", "mcritchie-studio", TASK, "hub-task")

    assert status.success?, "#{out}\n#{err}"
    context = JSON.parse(File.read(File.join(hub_desk, ".agent-context.json")))
    assert_equal 39_997, context.fetch("app_port")
    assert_equal "http://localhost:39997", context.fetch("local_url")
    assert_equal "mcritchie_studio_development_gem_lane_probe", context.fetch("database")
  end

  # The whole flow the card names: `bin/task begin --repo studio-engine` against a
  # local board sink, driving the REAL agent-worktree for steps 2 and 3. Only the
  # preflight and the claim move are stubbed; they are the board's half, not the desk's.
  test "[integration] task begin on studio-engine prints a usable desk" do
    repo = init_gem_repo("studio-engine")
    desk = File.join(repo, ".worktrees", TASK)
    with_board_sink(repo: "studio-engine") do |base, requests|
      out, err, status = begin_task(base)

      assert status.success?, "#{out}\n#{err}"
      refute_includes err, "unknown app"
      assert_includes out, "worktree: #{desk}"
      refute_match(/^port: \d/, out, "a gem desk prints no port")
      assert_includes out, "port:     none"
      refute_match(/^magic link:/, out, "nor a local review link, since nothing serves one")
      assert_equal "feat/#{TASK}", git_out(desk, "rev-parse", "--abbrev-ref", "HEAD")
      context = JSON.parse(File.read(File.join(desk, ".agent-context.json")))
      assert_equal TASK, context.fetch("task_record_slug"), "step 3 bound the desk to the task"
      assert_equal "Pokemon <pokemon@mcritchie.studio>",
                   git_out(desk, "var", "GIT_AUTHOR_IDENT").sub(/\s+\d+\s+[-+]\d{4}\z/, "")
      assert requests.any? { |line| line.start_with?("GET /api/v1/tasks/#{TASK}") }, requests.inspect
    end
  end

  private

  # The hub registry `apps` reads (<projects>/mcritchie-studio), as a plain repo.
  def init_hub
    hub = File.join(@projects_dir, "mcritchie-studio")
    init_repo(hub, ignore: "/.env*\n.agent-context.json\n/.worktrees/\n")
  end

  # A gem-lane repo as it sits on disk: a primary checkout whose .gitignore covers
  # only `.worktrees/` (as studio-engine's and solana-studio's do), and a bare origin
  # carrying `accepted`, which is what `new` fetches and cuts from.
  def init_gem_repo(name)
    repo = File.join(@projects_dir, name)
    init_repo(repo, ignore: "/.worktrees/\n")
    origin = File.join(@projects_dir, "origins", "#{name}.git")
    FileUtils.mkdir_p(File.dirname(origin))
    git_out(@projects_dir, "init", "-q", "--bare", origin)
    git_out(repo, "remote", "add", "origin", origin)
    git_out(repo, "push", "-q", "origin", "HEAD:refs/heads/accepted")
    git_out(repo, "fetch", "-q", "origin")
    repo
  end

  def init_repo(repo, ignore:)
    FileUtils.mkdir_p(repo)
    git_out(repo, "init", "-q")
    git_out(repo, "config", "user.email", "agent-test@example.com")
    git_out(repo, "config", "user.name", "Agent Test")
    git_out(repo, "checkout", "-q", "-b", "main")
    File.write(File.join(repo, ".gitignore"), ignore)
    git_out(repo, "add", ".gitignore")
    git_out(repo, "commit", "-q", "-m", "Initial commit")
  end

  # HOME and the global git config pointed at throwaway paths, and the identity
  # environment cleared, so neither the operator's ~/.gitconfig nor a runner's
  # exports answer for these repos.
  def scratch_git_env
    home = File.join(@projects_dir, ".scratch-home")
    FileUtils.mkdir_p(home)
    { "HOME" => home, "GIT_CONFIG_GLOBAL" => File.join(home, ".gitconfig"),
      "GIT_AUTHOR_NAME" => nil, "GIT_AUTHOR_EMAIL" => nil,
      "GIT_COMMITTER_NAME" => nil, "GIT_COMMITTER_EMAIL" => nil }
  end

  def git_out(dir, *args)
    out, err, status = Open3.capture3(SessionEnv.neutralized.merge(scratch_git_env), "git", *args, chdir: dir)
    assert status.success?, "git #{args.join(" ")} failed\n#{out}\n#{err}"
    out.strip
  end

  def worktree_env
    OutboundSeams.env({
      "PROJECTS_DIR" => @projects_dir,
      "AGENT_REDIS_CAPACITY_FILE" => File.join(@projects_dir, ".agents", "redis-capacity.json"),
      "AGENT_WORKTREE_LOCK" => File.join(@projects_dir, ".agents", "agent-worktree.lock"),
      "AGENT_WORKTREE_REGISTRY" => File.join(@projects_dir, ".agents", "registry.json"),
      "AGENT_WORKTREE_ORIGIN_FETCH" => "ok",
      "AGENT_WORKTREE_TASK_BIN" => OutboundSeams.stub("task-cli"),
      "LOCAL_EMAIL_CAPTURE" => "0"
    }.merge(@desk_ledger.env)).merge(scratch_git_env)
  end

  def agent_worktree(*args)
    Open3.capture3(worktree_env, RbConfig.ruby, WORKTREE_BIN, *args, chdir: @projects_dir)
  end

  def agent_worktree!(*args)
    out, err, status = agent_worktree(*args)
    assert status.success?, "agent-worktree #{args.join(" ")} failed\n#{out}\n#{err}"
    out
  end

  def begin_task(base)
    stubs = File.join(@projects_dir, "stubs")
    FileUtils.mkdir_p(stubs)
    %w[move-stub preflight-stub].each do |name|
      path = File.join(stubs, name)
      File.write(path, "#!/bin/sh\nexit 0\n")
      FileUtils.chmod(0o755, path)
    end
    env = worktree_env.merge(TaskUsageSandboxEnv.child_env(@projects_dir)).merge(
      "TASK_API_BASE" => base, "AGENT_API_SECRET" => "not-a-real-secret", "TASK_SKIP_MARKER" => "1",
      "AGENT_API_TOKEN" => nil, "CLAUDE_CODE_SESSION_ID" => nil, "CLAUDE_SESSION_ID" => nil,
      "CODEX_THREAD_ID" => nil,
      "TASK_BEGIN_PROJECTS_DIR" => @projects_dir,
      "TASK_BEGIN_WORKTREE_BIN" => WORKTREE_BIN,
      "TASK_BEGIN_MOVE_BIN" => File.join(stubs, "move-stub"),
      "TASK_BEGIN_PREFLIGHT_BIN" => File.join(stubs, "preflight-stub")
    )
    Open3.capture3(env, TASK_BIN, "begin", TASK, "--agent", "pokemon", chdir: @projects_dir)
  end

  # A one-thread board: the task (designed, on the gem repo) for every read, a token
  # for the auth exchange, and an empty 201 for anything begin posts.
  def with_board_sink(repo:)
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    task = { data: { slug: TASK, stage: "designed", title: "Gem Lane Desk",
                     metadata: { devops: { worktree_slug: TASK, repositories: [repo] } } } }.to_json
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
          if line.include?("/api/v1/auth") then [200, { token: "sink-bearer" }.to_json]
          elsif line.start_with?("POST /api/v1/agent_sessions") then [503, { error: "no sessions here" }.to_json]
          elsif line.start_with?("POST") then [201, { data: { slug: "row-1" } }.to_json]
          elsif line.include?("/api/v1/activities") then [200, { data: [] }.to_json]
          else [200, task]
          end
        client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{reply.bytesize}\r\n\r\n#{reply}")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    yield "http://127.0.0.1:#{server.addr[1]}", requests
  ensure
    server&.close
    thread&.kill
  end
end
