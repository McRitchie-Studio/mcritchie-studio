require "test_helper"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "time"
require "tmpdir"
require_relative "../support/desk_ledger_sink"

# A TEARDOWN THAT SPARES A PROCESS HAS NOT CLEANLY SUCCEEDED, and it must say so where a
# caller and the ledger can read it.
#
# #1430 and #1434 made `bin/agent-worktree` teardown SPARE a process it cannot prove runs
# from the desk (cwd_is_desk?). That is right: SIGTERM cannot be undone, and the pid a port
# or a pidfile names can belong to anybody. But the only trace was a stderr line. `remove`
# still exited 0 and the desk ledger still recorded a clean `removed`, so the /deployments
# Desks panel, a later sweep and every caller read a clean teardown while a process kept
# its port and its memory. The machine sat at ~95% swap on 2026-09-16 with a dozen stacks
# up; an invisible leak is how that accumulates.
#
# These tests hold each end of the fix against a REAL teardown, a REAL surviving process and
# a real HTTP ledger (DeskLedgerSink):
#   * the ledger closes the episode `leaked`, naming the spared pid, instead of `removed`;
#   * the command exits 3 and prints one `teardown-leak:` line per spared process;
#   * a leak inside `cleanup --reclaim --yes` is reported PER DESK and the batch runs on;
#   * the spared process is still never signalled.
#
# THROWAWAY HUBS ONLY. Every desk here lives under a tmpdir, and `lsof` is a fake that
# answers for this test's own processes, so nothing touches a real desk on the machine.
class AgentWorktreeTeardownLeakTest < ActiveSupport::TestCase
  LEAK_EXIT = 3

  def setup
    @projects_dir = File.realpath(Dir.mktmpdir("agent-worktree-teardown-leak"))
    @hub_dir = File.join(@projects_dir, "mcritchie-studio")
    @script = Rails.root.join("bin/agent-worktree").to_s
    @desk_ledger = DeskLedgerSink.start
    @stranger = spawn_stranger
    init_hub
    OutboundSeams.reset!
  end

  def teardown
    stop_stranger
    @desk_ledger&.stop
    FileUtils.rm_rf(@projects_dir) if @projects_dir
  end

  # [integration] THE DEFECT. The desk's pidfile names a live process that runs from
  # somewhere else, and the desk's port answers the same pid. The teardown must leave it
  # running (as before), and must now say so: exit 3, a `teardown-leak:` line, and a ledger
  # episode closed `leaked` rather than `removed`. On the pre-fix script this exits 0 and
  # the ledger reads `removed`.
  test "[integration] remove --yes that spares a process records it leaked and exits 3" do
    desk = add_desk("leak-desk", port: 39_101, redis_db: 9)
    write_web_pidfile(desk, stranger_pid)
    lsof = write_fake_lsof(ports: { 39_101 => stranger_pid }, cwds: { stranger_pid => @projects_dir })

    out, err, status = remove_desk("leak-desk", lsof)

    assert_equal LEAK_EXIT, status.exitstatus, "a teardown that left a process running is not a success\n#{out}\n#{err}"
    refute Dir.exist?(desk), "premise: the teardown itself ran to the end"
    assert stranger_alive?, "the spared process must still never be signalled\n#{out}\n#{err}"
    assert_includes out, "teardown-leak: mcritchie-studio/leak-desk pid #{stranger_pid}"

    records = @desk_ledger.desks_for(desk)
    assert_equal %w[removing leaked], records.map { |record| record["status"] },
                 "the record is opened BEFORE anything is destroyed, and closed with the outcome"
    leaked = records.last.fetch("leaked_processes")
    assert_equal [stranger_pid], leaked.map { |entry| entry["pid"] },
                 "one process, named once, although both the pidfile and the port pointed at it"
    assert_equal({ "pid" => stranger_pid, "label" => "web", "via" => "pidfile", "port" => 39_101, "cwd" => @projects_dir },
                 leaked.first)
    assert_includes records.last["reason"], "pid #{stranger_pid}",
                    "the Desks panel prints `reason` on a finished desk, so the leak has to lead it"
  end

  # [integration] THE CONTROL. The same teardown with the process rooted IN the desk: that is
  # the desk's own server, it is stopped, and the episode closes `removed` with exit 0. A
  # leak signal that fired on every teardown would be as useless as none.
  test "[integration] remove --yes that stops the desk's own server records removed and exits 0" do
    desk = add_desk("own-desk", port: 39_102, redis_db: 9)
    write_web_pidfile(desk, stranger_pid)
    lsof = write_fake_lsof(ports: { 39_102 => stranger_pid }, cwds: { stranger_pid => desk })

    out, err, status = remove_desk("own-desk", lsof)

    assert status.success?, "#{out}\n#{err}"
    assert_equal Signal.list.fetch("TERM"), stranger_exit_signal, "premise: the desk's own server gets SIGTERM"
    refute_includes out, "teardown-leak:"
    records = @desk_ledger.desks_for(desk)
    assert_equal %w[removing removed], records.map { |record| record["status"] }
    refute records.last.key?("leaked_processes"), "a clean teardown posts no leak evidence"
  end

  # [integration] ONE LEAK MUST NOT ABORT A BATCH. Two reclaimable desks; the FIRST one torn
  # down leaks. The second must still be reclaimed, each desk's outcome must be reported on
  # its own, and the sweep's exit carries the leak. bin/release parses "reclaimed N
  # worktree(s)", so that line must survive too.
  test "[integration] a leak in a reclaim batch is reported per desk and the batch runs on" do
    leaky = add_desk("leak-desk", port: 39_103, redis_db: 9)
    quiet = add_desk("quiet-desk", port: 39_104, redis_db: 10)
    write_web_pidfile(leaky, stranger_pid)
    abandon!(leaky, quiet)
    lsof = write_fake_lsof(ports: { 39_103 => stranger_pid }, cwds: { stranger_pid => @projects_dir })

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--reclaim", "--yes", env: removal_env(lsof))

    assert_equal LEAK_EXIT, status.exitstatus, "#{out}\n#{err}"
    leak_at = out.index("reclaimed mcritchie-studio/leak-desk")
    quiet_at = out.index("reclaimed mcritchie-studio/quiet-desk")
    assert leak_at && quiet_at && leak_at < quiet_at,
           "premise: the LEAKING desk is torn down first, so the second teardown proves the batch ran on\n#{out}\n#{err}"
    refute Dir.exist?(leaky)
    refute Dir.exist?(quiet)
    assert stranger_alive?

    assert_includes out, "teardown-leak: mcritchie-studio/leak-desk pid #{stranger_pid}"
    refute_includes out, "teardown-leak: mcritchie-studio/quiet-desk"
    assert_includes out, "reclaimed 2 worktree(s)"
    assert_includes out, "reclaim: 1 of 2 reclaimed desk(s) left a process running: mcritchie-studio/leak-desk (pid #{stranger_pid})"
    assert_equal "leaked", @desk_ledger.desk_for(leaky)["status"]
    assert_equal "removed", @desk_ledger.desk_for(quiet)["status"]
  end

  # [integration] AN OLDER BOARD. This CLI ships in worktrees while the board deploys on its
  # own cadence. A board that predates `removing` refuses it, and a fail-closed teardown
  # that took that refusal as an outage would refuse EVERY teardown until the deploy. It
  # files the removal the old way instead (one record, written first), and the leak is
  # still reported on the command line and in the exit code.
  test "[integration] against a board that predates the outcome states the leak is still reported" do
    @desk_ledger.stop
    @desk_ledger = DeskLedgerSink.start(refuse_statuses: %w[removing leaked])
    desk = add_desk("leak-desk", port: 39_105, redis_db: 9)
    write_web_pidfile(desk, stranger_pid)
    lsof = write_fake_lsof(ports: {}, cwds: { stranger_pid => @projects_dir })

    out, err, status = remove_desk("leak-desk", lsof)

    assert_equal LEAK_EXIT, status.exitstatus, "#{out}\n#{err}"
    refute Dir.exist?(desk), "an older board must not stop the teardown"
    assert stranger_alive?
    assert_equal %w[removed], @desk_ledger.desks_for(desk).map { |record| record["status"] },
                 "the legacy protocol: one `removed` record, filed before anything was destroyed"
    assert_includes err, "predates"
    assert_includes out, "teardown-leak: mcritchie-studio/leak-desk pid #{stranger_pid}"
  end

  private

  def stranger_pid = @stranger.fetch(:pid)

  # A separate, live process that is not any desk's server. It only has to be alive: the
  # fake lsof decides where it "runs from".
  def spawn_stranger
    pid = Process.spawn(RbConfig.ruby, "-e", "sleep 300", pgroup: true)
    { pid: pid }
  end

  def stranger_alive?
    Process.waitpid(stranger_pid, Process::WNOHANG).nil?
  end

  def stranger_exit_signal
    deadline = Time.now + 10
    until (reaped = Process.waitpid2(stranger_pid, Process::WNOHANG))
      return nil if Time.now > deadline

      sleep 0.05
    end
    @stranger[:reaped] = true
    reaped.last.termsig
  end

  def stop_stranger
    return if @stranger.nil? || @stranger[:reaped]

    Process.kill("KILL", stranger_pid)
    Process.waitpid(stranger_pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # An lsof that answers a teardown's two lookups for THIS test's ports and pids only:
  # who listens on a port, and a pid's cwd. Anything else gets lsof's own no-match answer.
  def write_fake_lsof(ports:, cwds:)
    path = File.join(@projects_dir, "fake-lsof-#{SecureRandom.hex(4)}")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      ports = #{ports.transform_keys(&:to_s).inspect}
      cwds = #{cwds.transform_keys(&:to_s).inspect}
      if (m = ARGV.join(" ").match(/iTCP:(\\d+) -sTCP:LISTEN\\z/)) && ports.key?(m[1])
        puts ports.fetch(m[1])
      elsif ARGV[0, 2] == ["-a", "-p"] && cwds.key?(ARGV[2])
        puts "p\#{ARGV[2]}", "fcwd", "n\#{cwds.fetch(ARGV[2])}"
      else
        exit 1
      end
    RUBY
    File.chmod(0o755, path)
    path
  end

  def write_web_pidfile(desk, pid)
    pidfile = File.join(desk, "tmp", "pids", "agent-web.pid")
    FileUtils.mkdir_p(File.dirname(pidfile))
    File.write(pidfile, "#{pid}\n")
  end

  def remove_desk(task, lsof)
    agent_worktree("remove", "mcritchie-studio", task, "--yes", env: removal_env(lsof))
  end

  def removal_env(lsof)
    { "AGENT_WORKTREE_LSOF_BIN" => lsof,
      "AGENT_WORKTREE_REGISTRY" => File.join(@projects_dir, ".agents", "registry.json"),
      "AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json }
  end

  # One hub repo whose origin/main is its own HEAD, so a desk branched from it with no
  # commits of its own is contained in base: clean and landed, the reclaim sweep's shape.
  def init_hub
    FileUtils.mkdir_p(@hub_dir)
    git!(@hub_dir, "init")
    git!(@hub_dir, "config", "user.email", "agent-test@example.com")
    git!(@hub_dir, "config", "user.name", "Agent Test")
    git!(@hub_dir, "checkout", "-b", "main")
    File.write(File.join(@hub_dir, ".gitignore"), ".env.agent-stack\n.agent-context.json\n/.worktrees/\n/tmp/\n")
    git!(@hub_dir, "add", ".gitignore")
    git!(@hub_dir, "commit", "-m", "Initial commit")
    git!(@hub_dir, "remote", "add", "origin", "git@github.com:McRitchie-Studio/mcritchie-studio.git")
    git!(@hub_dir, "update-ref", "refs/remotes/origin/main", "HEAD")
  end

  # The Redis port is unroutable and the database name unused, so the teardown's flush and
  # drop find nothing to act on.
  def add_desk(task, port:, redis_db:)
    dir = File.join(@hub_dir, ".worktrees", task)
    git!(@hub_dir, "worktree", "add", dir, "-b", "feat/#{task}")
    File.write(File.join(dir, ".env.agent-stack"), <<~ENVFILE)
      AGENT_WORKTREE=1
      APP_SLUG=mcritchie-studio
      TASK_SLUG=#{task}
      APP_PORT=#{port}
      PORT=#{port}
      REDIS_URL=redis://localhost:63999/#{redis_db}
      DATABASE_URL=postgresql://localhost/mcritchie_studio_development_teardown_leak_probe_#{task.tr("-", "_")}
      LOCAL_EMAIL_CAPTURE=1
    ENVFILE
    dir
  end

  # Old and untouched, so the reclaim sweep nominates the desks rather than withholding
  # newborns.
  def abandon!(*desks)
    at = Time.now - (3 * 24 * 60 * 60)
    desks.each do |desk|
      paths = Dir.glob(File.join(desk, "**", "*"), File::FNM_DOTMATCH)
                 .reject { |path| %w[. ..].include?(File.basename(path)) }
      (paths + [desk]).each { |path| File.utime(at, at, path) }
    end
  end

  def lapsed_claim_json
    JSON.generate("metadata" => { "devops" => {
                    "claimed_session" => "sess-dead", "claim_expires_at" => (Time.now - 3600).utc.iso8601
                  } })
  end

  def git!(dir, *args)
    out, err, status = Open3.capture3(SessionEnv.neutralized, "git", *args, chdir: dir)
    assert status.success?, "git #{args.join(" ")} failed\n#{out}\n#{err}"
  end

  def agent_worktree(*args, env: {})
    command_env = OutboundSeams.env({
      "PROJECTS_DIR" => @projects_dir,
      "AGENT_REDIS_CAPACITY_FILE" => File.join(@projects_dir, ".agents", "redis-capacity.json"),
      "AGENT_WORKTREE_LOCK" => File.join(@projects_dir, ".agents", "agent-worktree.lock"),
      "AGENT_WORKTREE_ORIGIN_FETCH" => "ok",
      "AGENT_WORKTREE_TASK_BIN" => OutboundSeams.stub("task-cli")
    }.merge(@desk_ledger.env).merge(env))
    Open3.capture3(command_env, RbConfig.ruby, @script, *args, chdir: Rails.root.to_s)
  end
end
