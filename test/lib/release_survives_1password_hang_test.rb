# frozen_string_literal: true

# release-survives-1password-hang: a hung 1Password costs the release under thirty seconds per
# read and one line naming it, never a silent fifteen-minute wait or a GitHub 401; `bin/release
# prepare|ship --wait-for-1password` waits it out and resumes the step.
# Every `op` here is a fake on PATH or behind a seam: none reaches the real 1Password, and no
# test value is a secret.
# History: task release-survives-1password-hang.

require "minitest/autorun"
require "open3"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "../support/session_env"
require_relative "../../bin/lib/op_meter"
require_relative "../../bin/lib/one_password_wait"

class ReleaseSurvives1PasswordHangTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  HELPER = File.join(ROOT, "bin", "gh-app-git-credential")
  GH_TOKEN = File.join(ROOT, "bin", "gh-token")
  SECRET = File.join(ROOT, "bin", "secret")
  SHIM = File.join(ROOT, "bin", "lib", "op-meter.sh")
  HUNG = "1Password is not answering"

  def setup
    @dir = Dir.mktmpdir("op-hang")
    @log = File.join(@dir, "op-reads.log")
    @calls = File.join(@dir, "calls.log")
    @grandchild = File.join(@dir, "grandchild.pid")
    OpMeter.reset_hang!
  end

  def teardown
    OpMeter.reset_hang!
    if File.exist?(@grandchild)
      pid = File.read(@grandchild).to_i
      Process.kill(:KILL, pid) if pid.positive? && alive?(pid)
    end
    FileUtils.rm_rf(@dir)
  end

  # A fake `op` named `op`, in its own directory, for PATH. It logs its argv and,
  # unless +answer_when+ exists, forks a grandchild that holds stdout and then
  # sleeps forever, so only a process-GROUP kill frees the caller's pipe. With
  # +answer_when+ present it answers at once.
  def fake_op(answer_when: nil)
    bindir = File.join(@dir, "bin")
    FileUtils.mkdir_p(bindir)
    path = File.join(bindir, "op")
    answer = answer_when ? %(if [ -e "#{answer_when}" ]; then printf 'not-a-secret'; exit 0; fi\n) : ""
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> "#{@calls}"
      #{answer}sleep 600 &
      echo $! > "#{@grandchild}"
      exec sleep 600
    SH
    File.chmod(0o755, path)
    path
  end

  def calls = File.exist?(@calls) ? File.readlines(@calls, chomp: true) : []
  def outcomes = File.exist?(@log) ? File.readlines(@log).map { |l| l.split("\t")[3] } : []

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::EPERM
    false
  end

  def gone_soon?(pid)
    20.times do
      return true unless alive?(pid)

      sleep 0.05
    end
    false
  end

  def pinned(extra = {})
    { "MCR_OP_READS_LOG" => @log, "MCR_OP_DEADLINE" => "0.5", "CLAUDE_PROJECTS_DIR" => @dir,
      "HOME" => @dir }.merge(extra)
  end

  def timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started]
  end

  # ── THE BOUND ──────────────────────────────────────────────────────────────

  # [unit] a fake op that sleeps forever is killed within the bound and yields the
  # named hang error, not a 401.
  def test_unit_a_hung_op_is_killed_by_process_group_and_named_once
    op = fake_op
    err = StringIO.new
    saved = $stderr
    $stderr = err
    out, seconds = timed do
      2.times.map { OpMeter.popen({}, [op, "read", "op://v/i/f"], via: "test", env: pinned) }
    end
    $stderr = saved

    assert_equal ["", ""], out
    assert_operator seconds, :<, 4, "two reads of two 0.5 s attempts, never the fake's 600 s"
    assert OpMeter.hung?
    assert OpMeter.last_hung?
    refute $?.success?, "a killed read is never a success to a `$?` caller"
    assert_equal 1, err.string.scan(HUNG).length, "one loud line per process, not one per read"
    assert_includes err.string, "Quit and reopen the 1Password app; reboot if that fails"
    assert_equal %w[timeout timeout timeout timeout], outcomes
    assert gone_soon?(File.read(@grandchild).to_i), "the group kill takes what op forked, too"
  ensure
    $stderr = saved if saved
  end

  def test_unit_the_two_attempt_default_stays_under_thirty_seconds
    assert_operator OpMeter::DEFAULT_DEADLINE * 2, :<, 30
    assert_includes File.read(SHIM), %(${MCR_OP_DEADLINE:-14})
  end

  # The shell half: no alarm, a group kill, and the line once per shell.
  def test_unit_the_shell_half_kills_the_group_and_names_the_hang_once
    op = fake_op
    script = %(. "#{SHIM}"; op_metered "$1" read op://v/i/f; a=$?; op_metered "$1" read op://v/i/f; echo "$a $?")
    (out, err, _status), seconds = timed do
      Open3.capture3(SessionEnv.neutralized(pinned), "bash", "-c", script, "t", op, in: File::NULL)
    end

    assert_equal "124 124", out.strip
    assert_operator seconds, :<, 8
    assert_equal 1, err.scan(HUNG).length
    assert gone_soon?(File.read(@grandchild).to_i), "the perl watchdog kills op's whole group"
    refute_includes File.read(SHIM)[/OP_METER_WATCHDOG='.*?'$/m], "alarm", "op ignores SIGALRM: no alarm in the bound"
  end

  # The credential helper on a hung 1Password: one bounded attempt pair, exit 75,
  # the hang named, and none of the vault advice that sent people chasing a 401.
  def test_unit_the_credential_helper_stops_on_a_hang_with_no_misleading_advice
    op = fake_op
    token = File.join(@dir, "fake-gh-token")
    File.write(token, "#!/bin/sh\nexit 1\n")
    File.chmod(0o755, token)
    env = SessionEnv.neutralized(pinned("GH_APP_OP_BIN" => op, "GH_APP_TOKEN_CMD" => token,
                                        "GH_APP_MINT_CMD" => "/nonexistent", "GH_APP_ITEM" => nil))
    (out, err, status), seconds = timed { Open3.capture3(env, HELPER, "get", stdin_data: "protocol=https\nhost=github.com\n\n") }

    assert_equal 75, status.exitstatus
    assert_empty out, "no credential, so git never sends one"
    assert_operator seconds, :<, 4
    assert_equal 1, err.scan(HUNG).length
    refute_match(/vault|op vault list|401/, err)
    assert_equal ["item get github.mcritchie-agent --vault studio-agents --format json"] * 2, calls,
                 "the item read and its uncached retry, then nothing: no app-id or key read after a hang"
  end

  def test_unit_the_credential_helper_spends_no_read_after_gh_token_reports_a_hang
    op = fake_op
    token = File.join(@dir, "fake-gh-token")
    File.write(token, "#!/bin/sh\necho 'gh-token: noise git never shows' >&2\nexit 75\n")
    File.chmod(0o755, token)
    env = SessionEnv.neutralized(pinned("GH_APP_OP_BIN" => op, "GH_APP_TOKEN_CMD" => token,
                                        "GH_APP_MINT_CMD" => "/nonexistent", "GH_APP_ITEM" => nil))
    _out, err, status = Open3.capture3(env, HELPER, "get", stdin_data: "protocol=https\nhost=github.com\n\n")

    assert_equal 75, status.exitstatus
    assert_equal 1, err.scan(HUNG).length
    assert_empty calls, "gh-token already spent the bound; the helper must not spend it again"
  end

  def test_unit_gh_token_exits_75_on_a_hung_read_not_the_sign_in_advice
    op = fake_op
    env = SessionEnv.neutralized(pinned("GH_TOKEN_OP_BIN" => op, "GH_TOKEN_MINT_BIN" => "/nonexistent"))
    (out, err, status), seconds = timed { Open3.capture3(env, GH_TOKEN, "--identity", "deployer", "--force") }

    assert_equal 75, status.exitstatus, err
    assert_empty out
    assert_operator seconds, :<, 4, "one read pair; the key is never asked for after a hung app-id"
    assert_equal 1, err.scan(HUNG).length
    refute_includes err, "is `op` signed in?"
    assert_equal 2, calls.length
  end

  def test_unit_bin_secret_names_the_hang_and_skips_the_read
    op = fake_op
    env = SessionEnv.neutralized(pinned("SECRET_OP_BIN" => op, "MCR_SECRET_CACHE_DIR" => File.join(@dir, "no-cache")))
    out, err, status = Open3.capture3(env, SECRET, "v", "i")

    assert_equal 75, status.exitstatus
    assert_empty out
    assert_equal 1, err.scan(HUNG).length
    refute_includes err, "not authenticated"
    assert_equal %w[whoami whoami], calls, "a hung whoami stops before the read"
  end

  # CONTROL: a healthy read is untouched (one call, its value, no hang).
  def test_unit_control_an_answering_op_is_not_a_hang
    marker = File.join(@dir, "answer")
    File.write(marker, "")
    op = fake_op(answer_when: marker)
    out = OpMeter.popen({}, [op, "read", "op://v/i/f"], via: "test", env: pinned)

    assert_equal "not-a-secret", out
    refute OpMeter.hung?
    assert_equal %w[ok], outcomes
  end

  # ── THE ABORT HINT ─────────────────────────────────────────────────────────

  def test_unit_timeouts_since_counts_only_this_runs_timeouts
    File.write(@log, [
      "2026-10-28T13:00:00Z\tgh-token\tread\ttimeout\tgh-token\t1\t-",
      "2026-10-28T13:10:00Z\tgh-token\tread\tok\tgh-token\t2\t-",
      "2026-10-28T13:10:05Z\tgh-app-git-credential\titem get\ttimeout\tx\t3\t-",
      "2026-10-28T13:10:25Z\tgh-app-git-credential\titem get\ttimeout\tx\t3\t-",
      "truncated\trow"
    ].join("\n") + "\n")

    assert_equal 2, OpMeter.timeouts_since(Time.utc(2026, 10, 28, 13, 5), env: pinned)
    assert_equal 0, OpMeter.timeouts_since(Time.utc(2026, 10, 28, 14), env: pinned)
    assert_equal 0, OpMeter.timeouts_since(Time.now, env: pinned("MCR_OP_READS_LOG" => File.join(@dir, "absent")))
  end

  # ── THE WAIT ───────────────────────────────────────────────────────────────

  # A clock the sleeper advances, so two-minute polls cost nothing.
  class FakeClock
    attr_reader :now

    def initialize = @now = Time.utc(2026, 10, 28, 14)
    def advance(seconds) = @now += seconds
  end

  def probe_with(op)
    -> { OnePasswordWait.probe(env: pinned, op_bin: op) }
  end

  # [unit] the wait-for-1password loop resumes when the fake op starts answering.
  def test_unit_the_wait_resumes_the_step_when_the_fake_op_starts_answering
    marker = File.join(@dir, "answer")
    op = fake_op(answer_when: marker)
    clock = FakeClock.new
    sleeps = []
    runs = []
    out = StringIO.new
    sleeper = lambda do |s|
      sleeps << s
      clock.advance(s)
      File.write(marker, "") if sleeps.length == 2 # 1Password comes back during the second wait
    end
    run_step = lambda do
      runs << clock.now
      runs.length == 1 ? 1 : 0 # fails on the hang, then succeeds
    end

    status = OnePasswordWait.supervise(step: "prepare", minutes: 60, run_step: run_step, probe: probe_with(op),
                                       sleeper: sleeper, clock: -> { clock.now }, out: out)

    assert_equal 0, status
    assert_equal 2, runs.length, "the same step ran again once 1Password answered"
    assert_equal [120, 120], sleeps, "polls every two minutes"
    assert_includes out.string, HUNG
    assert_includes out.string, "still not answering"
    assert_includes out.string, "1Password answered at"
    assert_includes out.string, "Resuming `bin/release prepare`"
  end

  # [unit] ... and gives up at the deadline.
  def test_unit_the_wait_gives_up_at_the_deadline
    op = fake_op
    clock = FakeClock.new
    sleeps = []
    out = StringIO.new
    runs = 0
    status = OnePasswordWait.supervise(step: "ship", minutes: 5, run_step: -> { runs += 1; 1 }, probe: probe_with(op),
                                       sleeper: ->(s) { sleeps << s; clock.advance(s) }, clock: -> { clock.now }, out: out)

    assert_equal OpMeter::HUNG_EXIT, status
    assert_equal 1, runs, "never re-ran a step 1Password could not serve"
    assert_equal [120, 120, 60], sleeps, "the last wait is cut to the deadline"
    assert_includes out.string, "still not answering after 5 minutes; gave up"
    assert_includes out.string, "re-run `bin/release ship`: it resumes"
  end

  # A failure that is not a hang is the step's own: returned at once, no wait.
  def test_unit_a_failure_with_1password_answering_is_returned_unwaited
    marker = File.join(@dir, "answer")
    File.write(marker, "")
    op = fake_op(answer_when: marker)
    out = StringIO.new
    status = OnePasswordWait.supervise(step: "prepare", minutes: 60, run_step: -> { 3 }, probe: probe_with(op),
                                       sleeper: ->(_) { flunk "no wait when 1Password answers" }, out: out)

    assert_equal 3, status, "prepare's QA-not-green exit passes through untouched"
    assert_empty out.string
  end

  def test_unit_a_green_step_never_probes
    status = OnePasswordWait.supervise(step: "ship", minutes: 60, run_step: -> { 0 },
                                       probe: -> { flunk "a green step spends no 1Password read" })
    assert_equal 0, status
  end

  def test_unit_the_flag_parses_bare_and_with_minutes_and_never_takes_the_next_token
    args = %w[--wait-for-1password --task some-slug]
    assert_equal 60, OnePasswordWait.take!(args)
    assert_equal %w[--task some-slug], args

    args = %w[--yes --wait-for-1password=15]
    assert_equal 15, OnePasswordWait.take!(args)
    assert_equal %w[--yes], args

    assert_nil OnePasswordWait.take!(%w[--yes])
    %w[0 -3 ten 1.5].each do |bad|
      assert_raises(OnePasswordWait::BadMinutes) { OnePasswordWait.take!(["--wait-for-1password=#{bad}"]) }
    end
  end

  # The release dispatch: the flag is refused off prepare/ship before anything runs.
  def test_unit_the_release_refuses_the_flag_on_another_subcommand
    out, err, status = Open3.capture3(SessionEnv.neutralized(pinned("RAILS_ENV" => "test")),
                                      RbConfig.ruby, File.join(ROOT, "bin", "release.rb"), "status", "--wait-for-1password")
    refute status.success?
    assert_includes out + err, "--wait-for-1password applies to `bin/release prepare` and `bin/release ship` only"
  end
end
