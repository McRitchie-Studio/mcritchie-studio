# frozen_string_literal: true

# OpMeter: the 1Password read-attribution log. THE TWO CONSTRAINTS THAT OUTRANK THE FEATURE:
#   1. IT MUST NOT COST A READ. Asserted with a RECORDING `op` stub (OpBinaryStub), count ZERO.
#   2. IT MUST NOT BREAK A CONSUMER WHEN op IS ABSENT OR RATE-LIMITED: every consumer has a
#      working fallback. Bash: test/commands/op_meter_fallback_test.rb, a booby-trapped `op`.
# History: task attribute-op-reads-to-caller.

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require_relative "../support/session_env"
require_relative "../support/op_binary_stub"
require_relative "../../bin/lib/op_meter"
require_relative "../../bin/lib/task_board"

class OpMeterTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  def with_log
    Dir.mktmpdir do |dir|
      log = File.join(dir, "op-reads.log")
      yield log, { "MCR_OP_READS_LOG" => log }, dir
    end
  end

  def rows(log)
    return [] unless File.exist?(log)

    File.readlines(log).map { |l| l.chomp.split("\t") }
  end

  # An executable that RECORDS being run and exits +code+. The point of a real
  # file on disk rather than a stubbed method: what costs a credential is a
  # SPAWNED PROCESS, and only a process on disk can prove one did not happen.
  def stub_op(dir, name: "op", code: 0, prints: "SECRET")
    path = File.join(dir, name)
    calls = File.join(dir, "#{name}-calls.log")
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$*" >> #{calls}
      printf '%s' '#{prints}'
      exit #{code}
    SH
    File.chmod(0o755, path)
    [path, calls]
  end

  def calls_in(path)
    File.exist?(path) ? File.readlines(path).map(&:chomp) : []
  end

  # ── the record itself ─────────────────────────────────────────────────────────

  def test_unit_popen_records_the_caller_action_and_outcome
    with_log do |log, env, dir|
      op, = stub_op(dir)
      out = OpMeter.popen({}, [op, "read", "op://v/i/f"], via: "task_board", env: env)

      assert_equal "SECRET", out
      assert_equal 1, rows(log).length, "one op call must record exactly one row"

      ts, caller, action, outcome, via, pid, _context = rows(log).first
      assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, ts, "the timestamp must be ISO8601 UTC")
      assert_equal File.basename($PROGRAM_NAME), caller, "the CALLING command is the attribution being asked for"
      assert_equal "read", action
      assert_equal "ok", outcome
      assert_equal "task_board", via, "the library seam is kept alongside the command, not instead of it"
      assert_equal Process.pid.to_s, pid
    end
  end

  # `op item get` must not flatten to `item`: WHICH KIND of call is the axis that
  # maps onto the quota, and an item get is a different cost story than a read.
  def test_unit_two_word_subcommands_are_recorded_whole
    with_log do |log, env, dir|
      op, = stub_op(dir)
      OpMeter.popen({}, [op, "item", "get", "agent.heroku", "--vault", "studio-agents"], via: "x", env: env)
      OpMeter.popen({}, [op, "vault", "list", "--format=json"], via: "x", env: env)
      OpMeter.popen({}, [op, "whoami"], via: "x", env: env)

      assert_equal ["item get", "vault list", "whoami"], rows(log).map { |r| r[2] }
    end
  end

  # The OPERAND must never reach the log. "op read op://vault/item/field" records
  # "read" — a secret's LOCATION is not something to append to a file that exists
  # to be read casually a month later.
  def test_unit_the_reference_operand_is_never_recorded
    with_log do |log, env, dir|
      op, = stub_op(dir)
      OpMeter.popen({}, [op, "read", "op://studio-agents/github.mcritchie-agent/app-id"], via: "x", env: env)

      refute_includes File.read(log), "github.mcritchie-agent",
                      "the log records WHICH KIND of call, never which secret"
      refute_includes File.read(log), "op://"
    end
  end

  def test_unit_a_failed_read_is_recorded_with_its_status
    with_log do |log, env, dir|
      op, = stub_op(dir, code: 3)
      OpMeter.popen({}, [op, "read", "op://v/i/f"], via: "x", env: env)

      assert_equal "fail:3", rows(log).first[3]
    end
  end

  # ── CONSTRAINT 1: the meter must not cost a read ─────────────────────────────

  # The direct proof. Drive the recorder hard with a recording `op` sitting where
  # a stray spawn would land, and assert it was NEVER executed. This is the test
  # that would catch a "cheap" refactor that shelled out for a timestamp, a
  # `whoami` to resolve the account, or an `op service-account ratelimit` to
  # annotate the row — the last of which is the exact trap the original
  # investigation fell into: that command COSTS A READ.
  def test_unit_recording_never_executes_op
    with_log do |log, env, dir|
      op, calls = stub_op(dir)

      40.times { |i| OpMeter.record(action: "read", outcome: "ok", via: "probe-#{i}", env: env) }

      assert_equal 40, rows(log).length, "the rows must actually have been written (a no-op would pass vacuously)"
      assert_empty calls_in(calls), "OpMeter.record spawned `op` — the instrument is consuming what it measures"
      assert_empty Dir.glob(File.join(dir, "*-calls.log")).reject { |f| f == calls },
                   "no other binary was executed either"
      refute_nil op
    end
  end

  # The same claim one level up, through the REAL consumer chain. TaskBoard's
  # secret chain spends exactly ONE read; metering it must still spend exactly
  # one. A meter that doubled the cost of the thing it measures would be a
  # spectacular own goal, and nothing else in the suite would notice.
  def test_unit_metering_adds_no_read_to_the_consumer_chain
    with_log do |log, env, dir|
      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |op|
        with_env(unset_ambient_secret(env)) { TaskBoard.agent_secret(File.join(dir, "no-such.env")) }

        assert_equal 1, op.count, "the chain must still spend exactly ONE read, not two"
        assert_equal 1, rows(log).length, "and that one read must be attributed"
        assert_equal "task_board", rows(log).first[4]
      end
    end
  end

  # ── CONSTRAINT 2: absent / rate-limited op ───────────────────────────────────

  # An absent `op` must reach the CALLER unchanged — every one of them has a
  # working fallback and metering may observe that path, never alter it.
  def test_unit_an_absent_op_still_raises_for_the_caller_and_is_recorded
    with_log do |log, env, dir|
      missing = File.join(dir, "definitely-not-here")

      assert_raises(Errno::ENOENT) do
        OpMeter.popen({}, [missing, "read", "op://v/i/f"], via: "x", env: env)
      end

      assert_equal "fail:127", rows(log).first[3],
                   "an attempt that spent nothing is still an attempt, and the bash half says 127 too"
    end
  end

  # The consumer's contract end-to-end: op gone, the chain still answers from its
  # .env instead of dying. This is the outage the ecosystem actually ran through.
  def test_unit_the_secret_chain_still_falls_back_when_op_is_gone
    with_log do |log, env, dir|
      dotenv = File.join(dir, ".env")
      File.write(dotenv, "AGENT_API_SECRET=from-dotenv\n")

      OpBinaryStub.with_stub(TaskBoard, dir: dir) do |_op|
        TaskBoard.send(:remove_instance_variable, :@op_secret) if TaskBoard.instance_variable_defined?(:@op_secret)
        OpBinaryStub.swap_const(TaskBoard, :OP, File.join(dir, "gone"))

        assert_equal "from-dotenv", with_env(unset_ambient_secret(env)) { TaskBoard.agent_secret(dotenv) }
      end

      assert_empty rows(log), "the .env answered before op was ever reached, so there is nothing to attribute"
    end
  end

  # A metering failure may never surface as a credential failure. A read-only log
  # is the cheapest way to make the write fail for real.
  def test_unit_an_unwritable_log_never_raises
    with_log do |_log, _env, dir|
      readonly = File.join(dir, "ro")
      FileUtils.mkdir_p(readonly)
      File.chmod(0o500, readonly)

      assert_nil OpMeter.record(action: "read", outcome: "ok", via: "x",
                                env: { "MCR_OP_READS_LOG" => File.join(readonly, "op-reads.log") })
    ensure
      File.chmod(0o700, File.join(dir, "ro"))
    end
  end

  # ── the sandbox posture: SKIP on rule 1, ABORT on rule 2 ─────────────────────

  # Rule 1. This is the ROUTINE test condition — task_board_test.rb drives the
  # whole secret chain in-process with no pin, because it has no store of its own
  # to pin — so an abort here would take the suite down over telemetry.
  def test_unit_an_armed_unpinned_run_skips_the_write_instead_of_aborting
    assert OpMeter.refused?({ "TASK_USAGE_SANDBOX" => "1" }),
           "armed and unpinned must refuse the write"
    assert_nil OpMeter.record(action: "read", outcome: "ok", via: "x",
                              env: { "TASK_USAGE_SANDBOX" => "1" })
  end

  def test_unit_an_armed_but_pinned_run_still_records
    with_log do |log, env, _dir|
      refute OpMeter.refused?(env.merge("TASK_USAGE_SANDBOX" => "1")),
             "a pinned destination is provable, so it must keep recording — failing closed on the " \
             "happy path would be worse than the leak it closes"
      OpMeter.record(action: "read", outcome: "ok", via: "x", env: env.merge("TASK_USAGE_SANDBOX" => "1"))

      assert_equal 1, rows(log).length
    end
  end

  # Case-insensitivity, matching TaskUsageSandbox::FALSEY. The two halves of this
  # guard disagreeing about whether it is ON is the bug bin/statusline documents.
  def test_unit_falsey_sandbox_spellings_are_read_as_disarmed
    %w[0 false no off FALSE Off].each do |value|
      refute OpMeter.refused?({ "TASK_USAGE_SANDBOX" => value }),
             "#{value.inspect} must read as DISARMED, exactly as TaskUsageSandbox reads it"
    end
  end

  # ── the reader ───────────────────────────────────────────────────────────────

  def test_unit_records_returns_empty_for_a_log_that_does_not_exist
    with_log do |_log, env, _dir|
      assert_empty OpMeter.records(env: env), "nothing recorded and no file are the same answer"
    end
  end

  def test_unit_records_parses_rows_with_string_keys
    with_log do |log, env, _dir|
      File.write(log, "2026-08-31T08:20:00Z\tgh-token\tread\tok\tgh-token\t99\tburst-1\n")
      row = OpMeter.records(env: env).first

      assert_equal "gh-token", row["caller"]
      assert_equal "read", row["action"]
      assert_equal "burst-1", row["context"]
    end
  end

  # A truncated row (a process killed mid-write) must not take the query down.
  def test_unit_a_truncated_row_is_skipped_not_fatal
    with_log do |log, env, _dir|
      File.write(log, "2026-08-31T08:20:00Z\tgh-token\tread\n" \
                      "2026-08-31T08:20:01Z\tgh-token\tread\tok\tgh-token\t99\t-\n")

      assert_equal 1, OpMeter.records(env: env).length
    end
  end

  # ── bin/op-reads answers the question the incident could not ─────────────────

  def test_integration_op_reads_attributes_the_spend_to_a_command
    with_log do |log, _env, _dir|
      File.write(log, [
        "2026-08-31T08:20:00Z\tgh-app-git-credential\titem get\tok\tghagc\t111\treview-fanout",
        "2026-08-31T08:20:01Z\tgh-app-git-credential\tread\tok\tghagc\t111\treview-fanout",
        "2026-08-31T08:20:02Z\tgh-app-git-credential\tread\tfail:1\tghagc\t111\treview-fanout",
        "2026-08-31T08:25:00Z\ttask\tread\tok\ttask_board\t222\t-"
      ].join("\n") + "\n")

      out, err, status = Open3.capture3(
        SessionEnv.neutralized("MCR_OP_READS_LOG" => log),
        File.join(ROOT, "bin", "op-reads"), "--all", "--json"
      )

      assert status.success?, "bin/op-reads failed: #{err}"
      report = JSON.parse(out)

      assert_equal 4, report["total"]
      top = report["groups"].first
      assert_equal "gh-app-git-credential", top["caller"],
                   "the heaviest spender must be named FIRST — that is the whole question"
      assert_equal 3, top["reads"]
      assert_equal 1, top["failed"]
    end
  end

  def test_integration_op_reads_says_so_plainly_when_nothing_is_recorded
    with_log do |log, _env, _dir|
      out, _err, status = Open3.capture3(
        SessionEnv.neutralized("MCR_OP_READS_LOG" => log),
        File.join(ROOT, "bin", "op-reads")
      )

      assert status.success?, "an empty log is not an error"
      assert_match(/no 1Password reads recorded/, out)
    end
  end

  # ── the meter must LOAD wherever bin/ travels ────────────────────────────────

  # THE REGRESSION. The meter lives in bin/lib; the sandbox guard lives in lib/, OUTSIDE the
  # bin/ tree, and the bin/ tree travels alone (bin/session-preflight runs from a HUB checkout;
  # test/commands/session_preflight_test.rb copies only `hub/bin`). A plain `require_relative
  # "../../lib/task_usage_sandbox"` raises LoadError there and, since bin/lib/task_board.rb
  # requires the meter, takes THE ENTIRE BOARD CLI down. It must hold at LOAD time. A fresh
  # process is required: `require` is cached.
  # History: task attribute-op-reads-to-caller.
  def test_integration_the_board_cli_still_loads_in_a_bin_only_tree
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(ROOT, "bin"), dir) # bin/ ONLY — deliberately no lib/
      log = File.join(dir, "op-reads.log")

      script = <<~RUBY
        require #{File.join(dir, 'bin', 'lib', 'task_board').inspect}
        OpMeter.record(action: "read", outcome: "ok", via: "probe",
                       env: { "MCR_OP_READS_LOG" => #{log.inspect} })
        puts "GUARD:\#{OpMeter::SANDBOX_AVAILABLE}"
        puts "BOARD:\#{TaskBoard.respond_to?(:agent_secret)}"
      RUBY

      out, err, status = Open3.capture3(SessionEnv.neutralized, RbConfig.ruby, "-e", script)

      assert status.success?, "the board CLI must load with no lib/ present: #{err}"
      assert_includes out, "BOARD:true", "TaskBoard must still be usable — it is how every lane writes"
      assert_includes out, "GUARD:false", "the guard is genuinely absent here, so the case is real"

      # FAIL CLOSED. With no guard reachable, nothing can prove the destination is
      # safe, so the meter records NOTHING rather than guessing.
      refute File.exist?(log),
             "with the sandbox guard unreachable the meter must write nothing at all"
    end
  end

  # ── the bound (2026-10-24): a hung op is killed at the deadline, retried once ──
  #
  # The stub is the 2026-10-21 failure in miniature: with the cache daemon in
  # play it never answers (it execs `sleep`, so the KILL lands on the process
  # holding stdout), and with OP_CACHE=false it answers at once, as
  # `op --cache=false` did that day.

  def hung_op(dir, retry_answers: true)
    path = File.join(dir, "op")
    calls = File.join(dir, "op-calls.log")
    answer = retry_answers ? "printf 'FRESH'; exit 0" : "exec sleep 600"
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s %s\n' "cache=${OP_CACHE:-unset}" "$*" >> #{calls}
      if [ "${OP_CACHE:-}" = "false" ]; then #{answer}; fi
      exec sleep 600
    SH
    File.chmod(0o755, path)
    [path, calls]
  end

  def test_unit_a_hung_op_times_out_and_the_uncached_retry_answers
    with_log do |log, env, dir|
      op, calls = hung_op(dir)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      out = OpMeter.popen({}, [op, "read", "op://v/i/f"], via: "task_board", env: env.merge("MCR_OP_DEADLINE" => "1"))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal "FRESH", out, "the retry's answer is the caller's answer"
      assert $?.success?, "callers read $? after the call: it must be the retry's status"
      assert_operator elapsed, :<, 5, "one deadline (1 s) and a fast retry, never the hung child's 600 s"
      assert_equal %w[timeout ok], rows(log).map { |r| r[3] }, "the log shows the timeout, then the retry"
      assert_equal ["cache=unset read op://v/i/f", "cache=false read op://v/i/f"], calls_in(calls),
                   "exactly one retry, and it bypasses the cache daemon"
    end
  end

  def test_unit_a_retry_that_also_hangs_fails_closed_after_two_deadlines
    with_log do |log, env, dir|
      op, calls = hung_op(dir, retry_answers: false)
      out = OpMeter.popen({}, [op, "read", "op://v/i/f"], via: "gh-token", env: env.merge("MCR_OP_DEADLINE" => "0.5"))

      assert_equal "", out
      refute $?.success?, "a killed op must never read as a success to a `$?.success?` caller"
      assert_equal %w[timeout timeout], rows(log).map { |r| r[3] }
      assert_equal 2, calls_in(calls).length, "one retry, not a loop"
    end
  end

  # CONTROL: a healthy op is untouched by the bound: one call, no retry, no
  # OP_CACHE in its environment, its stdout and status as before.
  def test_unit_control_a_fast_op_is_called_once_with_the_cache_untouched
    with_log do |log, env, dir|
      op, calls = hung_op(dir)
      File.write(op, <<~SH)
        #!/bin/sh
        printf '%s %s\n' "cache=${OP_CACHE:-unset}" "$*" >> #{calls}
        printf 'SECRET'
      SH
      out = OpMeter.popen({}, [op, "read", "op://v/i/f"], via: "agent_api", env: env.merge("MCR_OP_DEADLINE" => "1"))

      assert_equal "SECRET", out
      assert_equal ["cache=unset read op://v/i/f"], calls_in(calls)
      assert_equal %w[ok], rows(log).map { |r| r[3] }
    end
  end

  # Fourteen: an attempt and its uncached retry stay under thirty seconds.
  def test_unit_the_deadline_defaults_to_fourteen_seconds
    assert_equal 14, OpMeter.deadline({})
    assert_equal 14, OpMeter.deadline("MCR_OP_DEADLINE" => "nonsense")
    assert_equal 14, OpMeter.deadline("MCR_OP_DEADLINE" => "0")
    assert_in_delta 1.5, OpMeter.deadline("MCR_OP_DEADLINE" => "1.5")
  end

  # bin/op-reads counts timeouts in their own column, so a stuck daemon is one
  # glance away.
  def test_integration_op_reads_shows_the_timeouts
    with_log do |log, env, dir|
      op, = hung_op(dir)
      OpMeter.popen({}, [op, "read", "op://v/i/f"], via: "task_board", env: env.merge("MCR_OP_DEADLINE" => "0.5"))
      out, status = Open3.capture2(SessionEnv.neutralized(env), RbConfig.ruby, File.join(ROOT, "bin", "op-reads"))

      assert status.success?, out
      assert_match(/TIMEOUT/, out)
      json, = Open3.capture2(SessionEnv.neutralized(env), RbConfig.ruby, File.join(ROOT, "bin", "op-reads"), "--json")
      assert_equal 1, JSON.parse(json)["groups"].sum { |g| g["timeouts"] }
    end
  end


  private

  # ESTABLISH THE PREMISE. TaskBoard#agent_secret reads the REAL process ENV first
  # (bin/lib/task_board.rb#agent_secret), so a set AGENT_API_SECRET short-circuits .env and
  # vault. The cases on the chain's COST and .env FALLBACK need it unset. dotenv sets it from
  # the repo's .env once ANY Rails-loading test shares the process, so they pass alone and in CI
  # and fail beside an integration test under bin/fast-check.
  # nil is UNSET, not blank: `ENV[k] = nil` deletes the key and with_env restores it. A blank
  # string is the set-but-blank case the chain treats as absent.
  # History: task credential-helper-help-mints.
  def unset_ambient_secret(env) = env.merge("AGENT_API_SECRET" => nil)

  def with_env(overrides)
    original = overrides.keys.to_h { |k| [k, ENV.fetch(k, nil)] }
    overrides.each { |k, v| ENV[k] = v }
    yield
  ensure
    original&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

end
