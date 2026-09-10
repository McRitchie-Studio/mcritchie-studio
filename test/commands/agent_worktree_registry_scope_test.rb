require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../support/desk_ledger_sink"

# THE WORKTREE REGISTRY IS CROSS-APP, so no app-scoped command may write it.
#
# <projects>/.agents/worktree-registry.json holds every repo's desks, and bin/qa-intake
# triages from it. `bin/agent-worktree remove <app>` used to refresh it with a snapshot of
# THAT app alone, so removing one turf-monster desk rewrote the file with only
# turf-monster's desks. It then handed the desk ledger the same partial snapshot, and the
# ledger counts every open desk a newer snapshot did not list as vanished, so the Desks
# panel reported every other app's live desks as "left without a teardown record".
# `cleanup <app> --reclaim --yes` and `snapshot <app> --write` did the same. One scoped
# write reproduces it; no race is needed.
#
# Its own file because test/commands/agent_worktree_test.rb is a frozen append hotspot
# (config/test_health.yml). The harness below is the slice of that file's fixture these
# tests need: a real hub repo with one desk, a real board on localhost for the ledger,
# and the same outbound floor.
class AgentWorktreeRegistryScopeTest < ActiveSupport::TestCase
  def setup
    # realpath: git reports canonical paths, and macOS /var is a symlink into /private.
    @projects_dir = File.realpath(Dir.mktmpdir("agent-worktree-registry-scope"))
    @hub_dir = File.join(@projects_dir, "mcritchie-studio")
    @task = "hub-task"
    @worktree_dir = File.join(@hub_dir, ".worktrees", @task)
    @script = Rails.root.join("bin/agent-worktree").to_s
    # `remove` files its desk record on the board BEFORE it destroys anything and aborts
    # when it cannot, so the ledger has to be a real board, not a bypass.
    @desk_ledger = DeskLedgerSink.start
    setup_hub
  end

  def teardown
    @desk_ledger&.stop
    FileUtils.rm_rf(@projects_dir) if @projects_dir
  end

  # [integration] Three repos, one desk each: the hub, a registered satellite, and a
  # DISCOVERED repo (one with desks that is not in satellites.yml, the way the gem repos
  # are). The last one pins that a fix covering only the registered apps still fails.
  test "[integration] an app-scoped remove keeps every other app's desk in the registry and the ledger" do
    write_satellite("second-app", 3300)
    satellite_desk = add_repo_desk!("second-app", "satellite-task")
    discovered_desk = add_repo_desk!("gem-lib", "gem-task")
    git!(@hub_dir, "update-ref", "refs/remotes/origin/main", rev(@worktree_dir, "HEAD"))
    registry = File.join(@projects_dir, ".agents", "remove-registry.json")

    out, err, status = agent_worktree("remove", "mcritchie-studio", @task, "--yes",
                                      env: { "AGENT_WORKTREE_REGISTRY" => registry,
                                             "AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json })

    assert status.success?, "#{out}\n#{err}"
    refute Dir.exist?(@worktree_dir), "premise: the named desk is actually torn down"

    survivors = [satellite_desk, discovered_desk].sort
    assert_equal survivors, worktree_paths(JSON.parse(File.read(registry))),
                 "the registry must still list every other app's desk after one app's desk is removed"

    synced = @desk_ledger.synced.last
    assert synced, "premise: the remove hands the desk ledger a snapshot"
    assert_equal survivors, worktree_paths(synced),
                 "the ledger must be handed every desk still on disk, or it counts them as vanished"
  end

  # [integration] The same property through the command that names its scope most
  # plainly. `snapshot <app>` without --write only PRINTS, and keeps its app filter. With
  # --write it lands in the one cross-app file, so it must describe every desk.
  test "[integration] snapshot <app> --write still writes every app's desks" do
    write_satellite("second-app", 3300)
    satellite_desk = add_repo_desk!("second-app", "satellite-task")
    registry = File.join(@projects_dir, "registry.json")

    printed = JSON.parse(agent_worktree!("snapshot", "mcritchie-studio"))
    assert_equal [@worktree_dir], worktree_paths(printed),
                 "premise: the printed view is still scoped to the app it names"

    out = agent_worktree!("snapshot", "mcritchie-studio", "--write",
                          env: { "AGENT_WORKTREE_REGISTRY" => registry,
                                 "AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json })

    assert_includes out, "wrote 2 worktree record(s)"
    assert_includes out, "the app argument filters only the printed view",
                    "an operator who named one app must be told why the write covered them all"
    written = worktree_paths(JSON.parse(File.read(registry)))
    assert_equal [@worktree_dir, satellite_desk].sort, written
    assert_equal written, worktree_paths(@desk_ledger.synced.last)
  end

  # [unit] The same contract one level down, on run_snapshot itself: the app argument
  # reaches snapshot_payload for the printed view and never for a write. Every caller
  # (remove, the reclaim sweep, the snapshot command) goes through this one function, so
  # a new caller that passes its app along cannot bring the scoped write back.
  test "[unit] run_snapshot scopes the printed view but always writes every app" do
    snippet = <<~RUBY
      load #{@script.inspect}
      require "stringio"
      $asked = []
      def snapshot_payload(app = nil)
        $asked << (app && app.fetch("slug"))
        { "worktrees" => [] }
      end
      def sync_desk_ledger(_payload) = nil
      real, $stdout = $stdout, StringIO.new
      run_snapshot({ "slug" => "turf-monster" }, write: false)
      run_snapshot({ "slug" => "turf-monster" }, write: true)
      $stdout = real
      puts JSON.generate($asked)
    RUBY
    registry = File.join(@projects_dir, "unit-registry.json")
    out, err, status = Open3.capture3(
      SessionEnv.neutralized("PROJECTS_DIR" => @projects_dir, "AGENT_WORKTREE_REGISTRY" => registry,
                             "PATH" => ENV.fetch("PATH", "")),
      RbConfig.ruby, "-e", snippet
    )

    assert status.success?, "#{out}\n#{err}"
    assert_equal ["turf-monster", nil], JSON.parse(out.lines.last),
                 "the print keeps its app filter; the write asks for every app (nil)"
    assert_path_exists registry, "premise: the write really landed, in the pinned scratch file"
  end

  private

  def worktree_paths(payload)
    payload.fetch("worktrees").map { |desk| desk.fetch("worktree") }.sort
  end

  # The hub: a real repo with one feature desk, an ssh-form origin (so the outbound floor
  # makes any real fetch fail instantly) and a local refs/remotes/origin/main for base
  # resolution. Stack files are gitignored, as in the real repos, so the desk reads clean.
  def setup_hub
    init_repo(@hub_dir, "mcritchie-studio", ignore: ".env.agent-stack\n.agent-context.json\n/.worktrees/\n")
    FileUtils.mkdir_p(File.join(@hub_dir, "docs", "agents", "maintenance"))
    git!(@hub_dir, "worktree", "add", @worktree_dir, "-b", "feat/#{@task}")
    git!(@worktree_dir, "config", "user.email", "agent-test@example.com")
    git!(@worktree_dir, "config", "user.name", "Agent Test")
    File.write(File.join(@worktree_dir, "feature.txt"), "feature\n")
    git!(@worktree_dir, "add", "feature.txt")
    git!(@worktree_dir, "commit", "-m", "Add feature")
    # An unroutable Redis port and a database name nothing else uses: the teardown's
    # flush and drop find nothing to act on.
    File.write(File.join(@worktree_dir, ".env.agent-stack"), <<~ENVFILE)
      AGENT_WORKTREE=1
      APP_SLUG=mcritchie-studio
      TASK_SLUG=#{@task}
      APP_PORT=39999
      PORT=39999
      REDIS_URL=redis://localhost:63999/9
      DATABASE_URL=postgresql://localhost/mcritchie_studio_development_registry_scope_probe
      LOCAL_EMAIL_CAPTURE=1
    ENVFILE
  end

  # A second repo under the fixture projects root, with ONE desk of its own: the "other
  # app" whose desks a scoped write used to erase. Returns the desk's path. Register the
  # repo with write_satellite to make it an app; leave it out of satellites.yml and the
  # script discovers it from disk.
  def add_repo_desk!(slug, task)
    repo = File.join(@projects_dir, slug)
    init_repo(repo, slug, ignore: "/.worktrees/\n")
    desk = File.join(repo, ".worktrees", task)
    git!(repo, "worktree", "add", desk, "-b", "feat/#{task}")
    desk
  end

  def init_repo(repo, slug, ignore:)
    FileUtils.mkdir_p(repo)
    git!(repo, "init")
    git!(repo, "config", "user.email", "agent-test@example.com")
    git!(repo, "config", "user.name", "Agent Test")
    git!(repo, "checkout", "-b", "main")
    File.write(File.join(repo, ".gitignore"), ignore)
    git!(repo, "add", ".gitignore")
    git!(repo, "commit", "-m", "Initial commit")
    git!(repo, "remote", "add", "origin", "git@github.com:McRitchie-Studio/#{slug}.git")
    git!(repo, "update-ref", "refs/remotes/origin/main", "HEAD")
  end

  def write_satellite(slug, port)
    path = File.join(@hub_dir, "config", "satellites.yml")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, <<~YAML)
      satellites:
        - slug: #{slug}
          display_name: #{slug}
          port: #{port}
          status: active
    YAML
  end

  # A build claim that lapsed an hour ago: the board answers, and nobody holds the desk.
  def lapsed_claim_json
    JSON.generate("metadata" => { "devops" => {
                    "claimed_session" => "sess-dead", "claim_expires_at" => (Time.now - 3600).utc.iso8601
                  } })
  end

  def git!(dir, *args)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", *args, chdir: dir)
    assert status.success?, "git #{args.join(" ")} failed\n#{out}\n#{err}"
  end

  def rev(dir, ref)
    out, = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", ref, chdir: dir)
    out.strip
  end

  # The same floor test/commands/agent_worktree_test.rb spawns under: every store pinned
  # into the fixture root, origin fetches answered "ok", and the board CLI stubbed.
  def command_env(extra = {})
    OutboundSeams.env({
      "PROJECTS_DIR" => @projects_dir,
      "AGENT_REDIS_CAPACITY_FILE" => File.join(@projects_dir, ".agents", "redis-capacity.json"),
      "AGENT_WORKTREE_LOCK" => File.join(@projects_dir, ".agents", "agent-worktree.lock"),
      "AGENT_WORKTREE_ORIGIN_FETCH" => "ok",
      "AGENT_WORKTREE_TASK_BIN" => OutboundSeams.stub("task-cli")
    }.merge(@desk_ledger.env).merge(extra))
  end

  def agent_worktree(*args, env: {})
    Open3.capture3(command_env(env), RbConfig.ruby, @script, *args, chdir: Rails.root.to_s)
  end

  def agent_worktree!(*args, env: {})
    out, err, status = agent_worktree(*args, env: env)
    assert status.success?, "#{out}\n#{err}"
    out
  end
end
