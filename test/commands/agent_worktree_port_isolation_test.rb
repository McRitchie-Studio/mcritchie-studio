require "test_helper"
require "fileutils"
require "io/wait"
require "json"
require "open3"
require "rbconfig"
require "time"
require "tmpdir"
require_relative "../support/desk_ledger_sink"

# A COMMAND TEST MUST NOT READ, OR SIGNAL, A PORT IT DOES NOT OWN.
#
# Hub release-push CI run 35092204659 (job `rails (2)`, 2026-09-16) failed twice at once in
# test/commands/agent_worktree_test.rb, while something on the runner was LISTENING on
# 39999, the fixture desk's APP_PORT. 39999 is inside Linux's default ephemeral range, and
# every test in that file starts an in-process DeskLedgerSink on port 0, so the kernel can
# place a sibling WORKER's sink there.
#
#   * "cleanup write records operational context in the ledger" read `health port-busy`
#     where it asserts `health down`. The probe was reading the runner, not the fixture.
#   * a worker died mid-test: `RuntimeError: result not reported`, with two Open3 reader
#     threads raising `stream closed in another thread` a second after the port-busy
#     failure. A teardown test's `stop_generic_rails` sends SIGTERM to the pid on 39999;
#     when that pid is a worker blocked in Open3.capture3, Minitest lets the
#     SignalException through and the log shows exactly those lines.
#
# Both were reproduced locally on the pre-fix code by occupying the port deliberately; the
# CI log itself cannot name the pid. The fix has two halves, and this file proves each end
# to end:
#   * the port readers (lsof, curl) are named seams, and the OutboundSeams floor answers
#     them for every harness, so no command test reads a real port by default;
#   * a teardown signals a port holder only when that process is rooted in the desk, and
#     the pid a desk's pidfile names takes the same check (the OS recycles pids).
#
# Its own file because test/commands/agent_worktree_test.rb is a frozen hotspot at its
# line ceiling. The fixture is the slice of that file's harness these tests need.
class AgentWorktreePortIsolationTest < ActiveSupport::TestCase
  def setup
    @projects_dir = File.realpath(Dir.mktmpdir("agent-worktree-port-isolation"))
    @hub_dir = File.join(@projects_dir, "mcritchie-studio")
    @task = "port-desk"
    @worktree_dir = File.join(@hub_dir, ".worktrees", @task)
    @script = Rails.root.join("bin/agent-worktree").to_s
    @desk_ledger = DeskLedgerSink.start
    @stranger = spawn_stranger
    setup_hub(port: @stranger.fetch(:port))
    OutboundSeams.reset!
  end

  def teardown
    stop_stranger
    @desk_ledger&.stop
    FileUtils.rm_rf(@projects_dir) if @projects_dir
  end

  # [integration] THE PROBE, under a port that is GENUINELY busy: a live process of this
  # test's own holds the desk's APP_PORT for the whole run. The floor's reader answers
  # "nothing listens", so the record says `down`, and the receipts prove both reads went
  # to the seam rather than to the port. On the pre-fix script this reads `port-busy`.
  test "[integration] cleanup --write records health down while the desk's port is really held" do
    abandon_desk!

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--write")

    assert status.success?, "#{out}\n#{err}"
    desk = @desk_ledger.desk_for(@worktree_dir)
    assert desk, "cleanup --write must file the candidate on the desk ledger"
    assert_includes desk["reason"], "health down, Redis DB 9",
                    "the probe read the machine instead of the fixture: port #{port} is held by pid " \
                    "#{@stranger.fetch(:pid)}, and nothing in this test asked for that to matter"
    assert_includes OutboundSeams.calls_to("port-lsof"), "port-lsof -tiTCP:#{port} -sTCP:LISTEN",
                    "the listener lookup must go to the sealed reader"
    assert_includes OutboundSeams.calls_to("port-curl"),
                    "port-curl -sS -o /dev/null -m 2 -w %{http_code} http://localhost:#{port}/up",
                    "the /up read must go to the sealed reader"
  end

  # [integration] THE NON-VACUITY CONTROL for the test above. A health field that were a
  # constant would pass it, so here the reader says the port IS held and the record must
  # follow it. The ledger context tracks the reader, whatever the machine is doing.
  test "[integration] the recorded health follows the injected reader, not a constant" do
    abandon_desk!
    lsof = write_fake_lsof(pid: @stranger.fetch(:pid), cwd: @projects_dir)

    out, err, status = agent_worktree("cleanup", "mcritchie-studio", "--write",
                                      env: { "AGENT_WORKTREE_LSOF_BIN" => lsof })

    assert status.success?, "#{out}\n#{err}"
    assert_includes @desk_ledger.desk_for(@worktree_dir)["reason"], "health port-busy, Redis DB 9"
  end

  # [integration] THE WORKER DEATH, end to end: a real teardown and a real process on the
  # desk's port that is NOT the desk's server. It must survive, and the teardown must say
  # why it left it alone. On the pre-fix script the stranger dies of SIGTERM.
  test "[integration] remove --yes leaves a foreign process on the desk's port running" do
    lsof = write_fake_lsof(pid: @stranger.fetch(:pid), cwd: @projects_dir)

    out, err, status = remove_desk(lsof)

    # 3, not 0: a teardown that spared a process reports the leak (agent_worktree_teardown_leak_test.rb).
    assert_equal 3, status.exitstatus, "#{out}\n#{err}"
    refute Dir.exist?(@worktree_dir), "premise: the teardown really ran"
    assert stranger_alive?, "the teardown signalled pid #{@stranger.fetch(:pid)}, which is not the desk's " \
                            "server — on a CI runner that pid can be a sibling test worker\n#{out}\n#{err}"
    assert_includes err, "port #{port} is held by pid #{@stranger.fetch(:pid)} (cwd #{@projects_dir})"
  end

  # [integration] THE CONTROL. The same teardown with the holder rooted IN the desk: that is
  # the desk's own server, and it must still be stopped, or the guard is a leak.
  test "[integration] remove --yes still stops the desk's own server on its port" do
    lsof = write_fake_lsof(pid: @stranger.fetch(:pid), cwd: @worktree_dir)

    out, err, status = remove_desk(lsof)

    assert status.success?, "#{out}\n#{err}"
    assert_includes out, "stopped web pid #{@stranger.fetch(:pid)} on port #{port}"
    assert_equal Signal.list.fetch("TERM"), stranger_exit_signal, "the desk's server gets SIGTERM"
  end

  # [integration] A RECYCLED PID, end to end. The desk's pidfile names a live process that is
  # not the desk's server: the server died and the OS handed its pid to something else. It
  # must survive a real teardown. On the pre-fix script the pidfile branch signals it.
  test "[integration] remove --yes leaves a stranger holding the pidfile's pid running" do
    write_web_pidfile(@stranger.fetch(:pid))
    lsof = write_fake_lsof(pid: @stranger.fetch(:pid), cwd: @projects_dir)

    out, err, status = remove_desk(lsof)

    assert_equal 3, status.exitstatus, "#{out}\n#{err}"
    refute Dir.exist?(@worktree_dir), "premise: the teardown really ran"
    assert stranger_alive?, "the teardown signalled pid #{@stranger.fetch(:pid)}, which the desk's pidfile " \
                            "names but which runs from #{@projects_dir}\n#{out}\n#{err}"
    assert_includes err, "web pidfile names pid #{@stranger.fetch(:pid)} (cwd #{@projects_dir})"
  end

  # [integration] THE CONTROL. The same pidfile naming a process rooted IN the desk is the
  # desk's own server, and the pidfile branch (not the port fallback) must still stop it.
  test "[integration] remove --yes still stops the desk's own server named by its pidfile" do
    write_web_pidfile(@stranger.fetch(:pid))
    lsof = write_fake_lsof(pid: @stranger.fetch(:pid), cwd: @worktree_dir)

    out, err, status = remove_desk(lsof)

    assert status.success?, "#{out}\n#{err}"
    assert_match(/^stopped web pid #{@stranger.fetch(:pid)}$/, out, "stopped through the pidfile, not the port")
    assert_equal Signal.list.fetch("TERM"), stranger_exit_signal, "the desk's server gets SIGTERM"
  end

  private

  def write_web_pidfile(pid)
    pidfile = File.join(@worktree_dir, "tmp", "pids", "agent-web.pid")
    FileUtils.mkdir_p(File.dirname(pidfile))
    File.write(pidfile, "#{pid}\n")
  end

  def port = @stranger.fetch(:port)

  # A separate process that genuinely LISTENS on a port the kernel picked, the way a
  # sibling worker's sink does. It prints the port and sleeps until stopped.
  def spawn_stranger
    reader, writer = IO.pipe
    pid = Process.spawn(RbConfig.ruby, "-rsocket", "-e",
                        'server = TCPServer.new("127.0.0.1", 0); puts server.addr[1]; STDOUT.flush; sleep 300',
                        out: writer, pgroup: true)
    writer.close
    ready = reader.wait_readable(20)
    line = ready && reader.gets
    reader.close
    assert line, "premise: the stranger never reported its port"
    { pid: pid, port: line.strip }
  end

  def stranger_alive?
    Process.waitpid(@stranger.fetch(:pid), Process::WNOHANG).nil?
  end

  # Waits for the stranger and answers the signal that ended it (nil for a normal exit).
  def stranger_exit_signal
    deadline = Time.now + 10
    until (reaped = Process.waitpid2(@stranger.fetch(:pid), Process::WNOHANG))
      return nil if Time.now > deadline

      sleep 0.05
    end
    @stranger[:reaped] = true
    reaped.last.termsig
  end

  def stop_stranger
    return unless @stranger
    return if @stranger[:reaped]

    Process.kill("KILL", @stranger.fetch(:pid))
    Process.waitpid(@stranger.fetch(:pid))
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  # An lsof that answers the two lookups a teardown makes, for the desk's port only.
  # Anything else gets lsof's own no-match answer (exit 1, no output).
  def write_fake_lsof(pid:, cwd:)
    path = File.join(@projects_dir, "fake-lsof-#{SecureRandom.hex(4)}")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      if ARGV == ["-tiTCP:#{port}", "-sTCP:LISTEN"] || ARGV == ["-nP", "-iTCP:#{port}", "-sTCP:LISTEN"]
        puts "#{pid}"
      elsif ARGV == ["-a", "-p", "#{pid}", "-d", "cwd", "-Fn"]
        puts "p#{pid}", "fcwd", "n#{cwd}"
      else
        exit 1
      end
    RUBY
    File.chmod(0o755, path)
    path
  end

  def remove_desk(lsof)
    agent_worktree("remove", "mcritchie-studio", @task, "--yes",
                   env: { "AGENT_WORKTREE_LSOF_BIN" => lsof,
                          "AGENT_WORKTREE_REGISTRY" => File.join(@projects_dir, ".agents", "registry.json"),
                          "AGENT_WORKTREE_TASK_JSON" => lapsed_claim_json })
  end

  # One hub repo with one merged feature desk whose stack env names the stranger's port.
  # The Redis port is unroutable and the database name unused, so the teardown's flush and
  # drop find nothing to act on.
  def setup_hub(port:)
    FileUtils.mkdir_p(File.join(@hub_dir, "docs", "agents", "maintenance"))
    git!(@hub_dir, "init")
    git!(@hub_dir, "config", "user.email", "agent-test@example.com")
    git!(@hub_dir, "config", "user.name", "Agent Test")
    git!(@hub_dir, "checkout", "-b", "main")
    File.write(File.join(@hub_dir, ".gitignore"), ".env.agent-stack\n.agent-context.json\n/.worktrees/\n/tmp/\n")
    git!(@hub_dir, "add", ".gitignore")
    git!(@hub_dir, "commit", "-m", "Initial commit")
    git!(@hub_dir, "remote", "add", "origin", "git@github.com:McRitchie-Studio/mcritchie-studio.git")
    git!(@hub_dir, "worktree", "add", @worktree_dir, "-b", "feat/#{@task}")
    git!(@worktree_dir, "config", "user.email", "agent-test@example.com")
    git!(@worktree_dir, "config", "user.name", "Agent Test")
    File.write(File.join(@worktree_dir, "feature.txt"), "feature\n")
    git!(@worktree_dir, "add", "feature.txt")
    git!(@worktree_dir, "commit", "-m", "Add feature")
    git!(@hub_dir, "update-ref", "refs/remotes/origin/main", rev(@worktree_dir, "HEAD"))
    File.write(File.join(@worktree_dir, ".env.agent-stack"), <<~ENVFILE)
      AGENT_WORKTREE=1
      APP_SLUG=mcritchie-studio
      TASK_SLUG=#{@task}
      APP_PORT=#{port}
      PORT=#{port}
      REDIS_URL=redis://localhost:63999/9
      DATABASE_URL=postgresql://localhost/mcritchie_studio_development_port_isolation_probe
      LOCAL_EMAIL_CAPTURE=1
    ENVFILE
  end

  # Old and untouched, so the desk channel nominates it rather than withholding a newborn.
  def abandon_desk!
    at = Time.now - (3 * 24 * 60 * 60)
    paths = Dir.glob(File.join(@worktree_dir, "**", "*"), File::FNM_DOTMATCH)
               .reject { |path| %w[. ..].include?(File.basename(path)) }
    (paths + [@worktree_dir]).each { |path| File.utime(at, at, path) }
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

  def rev(dir, ref)
    out, = Open3.capture3(SessionEnv.neutralized, "git", "rev-parse", ref, chdir: dir)
    out.strip
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
