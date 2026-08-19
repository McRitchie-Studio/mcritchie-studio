# frozen_string_literal: true

# Guard: every apt fetch in CI is BOUNDED AT THE STEP and RETRIES.
#
# test/lib/ci_job_timeout_test.rb is the sibling of this file and bounds the
# JOB. Read them together; they are the same incident at two grains, and the
# distinction is the entire reason this file exists.
#
# WHAT THE JOB-LEVEL BOUND ALREADY DID. `timeout-minutes: 45` on every job
# replaced GitHub's six-hour default, which is why a stalled fetch now dies in
# 45 minutes instead of running until someone cancels it by hand. That mattered:
# a hung run cannot be `gh run rerun`, so before it, a stall blocked the retry
# as well as the run.
#
# WHAT IT COULD NOT DO. It turns "hangs forever" into "fails", and stops there.
# On 2026-08-19 that was still not enough — the same fetch stalled FOUR times
# across five PRs (#930, #931, #932, #923, #934), every one on the same line:
#
#   Get:5 https://archive.ubuntu.com/ubuntu noble-security InRelease [126 kB]
#   ...42 minutes of total silence...
#   ##[error]The operation was canceled.
#
# Four green branches went red, each costing ~45 minutes of runner time per
# affected job and a human to work out that nothing was wrong with the code.
# A step-level bound plus a retry turns that into "recovers in 90 seconds".
#
# WHY THIS TEST RUNS THE REAL SHELL RATHER THAN GREPPING FOR IT. A guard that
# only asserts `timeout-minutes` is present cannot tell a loop that retries from
# a loop that runs once and returns, and the retry is the half that does the
# work. So the `run:` body is lifted VERBATIM out of ci.yml and executed against
# a stubbed apt-get that stalls on command. Two things are deliberately faked,
# and nothing else:
#
#   * the BUDGETS, rewritten 90/300/900 -> 1/1/1, so the suite takes a second
#     instead of 22 minutes. The retry COUNT, the ordering, the dpkg repair, and
#     the exit codes are all the real ones.
#   * `timeout` ITSELF, which is GNU coreutils and absent from a developer Mac.
#     Faking it is what lets this file run everywhere instead of skipping into
#     decoration on half the machines that matter — and the stub RECORDS its
#     arguments, so deleting `timeout -k 10` from ci.yml is caught by the
#     assertion that it was invoked, not merely by the loop misbehaving.
require "minitest/autorun"
require "yaml"
require "tmpdir"
require "fileutils"

class CiAptStepTimeoutTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  WORKFLOW_GLOB = File.join(ROOT, ".github/workflows/*.yml")

  # A step bound is only meaningful below the 45-minute JOB bound it sits under.
  # 25 leaves the escalating budgets (90 + 300 + 900 + overhead) room to complete
  # on their own terms, and still fails a step well before the job gives up.
  STEP_CEILING = 30

  # The harness's own deadline. Every scenario below is engineered to finish in
  # about a second; anything approaching this means the run-body stopped
  # honouring its bound, which is precisely the defect under guard. Enforced in
  # Ruby because the machine may have no `timeout` to enforce it with.
  HARNESS_DEADLINE = 45

  def apt_steps
    paths = Dir[WORKFLOW_GLOB].sort
    refute_empty paths, "no workflows at #{WORKFLOW_GLOB} — this guard is looking in the wrong place"

    paths.flat_map do |path|
      jobs = (YAML.load_file(path, aliases: true) || {})["jobs"] || {}
      jobs.flat_map do |job_name, job|
        next [] unless job.is_a?(Hash)

        Array(job["steps"]).select { |s| s.is_a?(Hash) && s["run"].to_s.include?("apt-get") }
                           .map { |s| { file: File.basename(path), job: job_name, step: s } }
      end
    end
  end

  # ---- the drift guards -----------------------------------------------------

  def test_every_apt_step_declares_its_own_bound
    steps = apt_steps

    # Vacuity guard: green must mean "every fetch checked", never "no fetches
    # found". A rename of the step or a move of the workflow silently empties
    # this whole file otherwise.
    assert_operator steps.length, :>=, 3,
                    "expected at least the three known apt steps (test, playwright, island_animator); " \
                    "found #{steps.length}. If a fetch moved, follow it here — do not delete the guard."

    unbounded = steps.reject { |s| s[:step]["timeout-minutes"] }
                     .map { |s| "#{s[:file]} :: #{s[:job]} :: #{s[:step]['name']}" }
    assert_empty unbounded,
                 "these apt steps carry no step-level `timeout-minutes`, so a stalled mirror runs until " \
                 "the 45-minute JOB bound kills the whole job — unrecoverably, with no retry:\n  " +
                 unbounded.join("\n  ")

    too_large = steps.select { |s| s[:step]["timeout-minutes"].to_i > STEP_CEILING }
                     .map { |s| "#{s[:job]} :: #{s[:step]['name']} (#{s[:step]['timeout-minutes']}m)" }
    assert_empty too_large,
                 "a step bound above #{STEP_CEILING}m is not distinguishable from the 45m job bound it " \
                 "sits under, so it buys nothing:\n  " + too_large.join("\n  ")
  end

  def test_every_apt_step_delegates_its_bound_to_timeout
    missing = apt_steps.reject { |s| s[:step]["run"] =~ /timeout\s+-k\s+\d+\s+"?\$\{?budget/ }
                       .map { |s| "#{s[:job]} :: #{s[:step]['name']}" }

    assert_empty missing,
                 "`timeout-minutes` alone only kills the STEP — it cannot retry. These steps do not wrap " \
                 "the fetch in `timeout -k <n> $budget`, so there is nothing to retry after:\n  " +
                 missing.join("\n  ")
  end

  # ---- the behavioural guards, running the real run-body --------------------

  def test_a_persistent_stall_is_killed_retried_three_times_and_fails
    result = run_step(mode: "stall")

    refute_equal 0, result[:status],
                 "a mirror that never responds must FAIL the step. It exited 0, so CI would proceed " \
                 "without the packages installed."

    assert_equal 3, result[:apt_calls],
                 "expected exactly 3 attempts against the stalling mirror, saw #{result[:apt_calls]}. " \
                 "One attempt means the retry is gone; more than three means the loop lost its bound."

    assert_equal 3, result[:timeout_calls].length,
                 "the fetch must be wrapped in `timeout` on EVERY attempt, not just the first"

    assert(result[:timeout_calls].all? { |c| c.start_with?("-k 10 ") },
           "every attempt must pass `-k 10`: timeout sends SIGTERM first, and a wedged apt need not " \
           "honour it — an attempt that ignores its own bound defeats the step. Saw: #{result[:timeout_calls].inspect}")

    assert_equal 3, result[:dpkg_calls],
                 "each killed attempt must run `dpkg --configure -a` before the next, or an attempt " \
                 "killed mid-unpack fails the following one for a reason unrelated to the network"

    assert_includes result[:output], "::error::",
                    "a three-times-failed fetch must annotate the run, so the cause reads off the " \
                    "checks page instead of out of a 40-minute log"
  end

  def test_a_transient_stall_recovers_on_a_later_attempt
    # Stalls attempts 1 and 2, answers on 3 — the shape of the real incident,
    # where the mirror recovers within minutes. This is the case the whole
    # change exists to convert from a red PR into a non-event.
    result = run_step(mode: "flaky", ok_on: 3)

    assert_equal 0, result[:status],
                 "a mirror that answers on the third attempt must PASS. It failed, which means the " \
                 "retry is not actually recovering — the reds this change removes would still land.\n" +
                 result[:output]

    assert_includes result[:output], "::notice::",
                    "a recovered fetch should say so, so a slow run is legible without reading the log"
  end

  def test_a_healthy_mirror_costs_exactly_one_attempt
    result = run_step(mode: "healthy")

    assert_equal 0, result[:status], "a healthy fetch must pass:\n#{result[:output]}"

    # update + install, once each. The ordinary case measured 10-16 seconds; a
    # retry loop that re-runs a SUCCEEDING fetch would triple every CI run.
    assert_equal 2, result[:apt_calls],
                 "a healthy mirror must be hit exactly twice (update, install), not #{result[:apt_calls]}"

    refute_includes result[:output], "::warning::",
                    "a healthy fetch must not warn — a step that cries wolf on every green run trains " \
                    "everyone to ignore it on the red one"
  end

  private

  # Lifts the FIRST apt step's `run:` out of ci.yml and executes it against
  # stubs. Returns the exit status, the combined output, and what the stubs saw.
  def run_step(mode:, ok_on: 1)
    step = apt_steps.first[:step]
    body = step["run"].dup

    # The one declared rewrite: real budgets would make this test take 22
    # minutes. Everything else about the loop is executed as written.
    assert_match(/for budget in 90 300 900/, body,
                 "the run-body no longer declares the escalating budgets this test rewrites; " \
                 "re-read ci.yml before trusting anything below")
    body.sub!("for budget in 90 300 900", "for budget in 1 1 1")

    Dir.mktmpdir("apt-step") do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      apt_count    = File.join(dir, "apt.count")
      timeout_log  = File.join(dir, "timeout.log")
      dpkg_count   = File.join(dir, "dpkg.count")

      # sudo: run the command, nothing more. The real one adds privilege; the
      # loop's behaviour does not depend on having it.
      write_stub File.join(bin, "sudo"), <<~SH
        exec "$@"
      SH

      # timeout: faithful enough to bound a child, and it RECORDS its arguments
      # so the test can prove ci.yml still delegates to it.
      write_stub File.join(bin, "timeout"), <<~SH
        echo "$*" >> "#{timeout_log}"
        k=0
        if [ "$1" = "-k" ]; then k="$2"; shift 2; fi
        budget="$1"; shift
        "$@" &
        child=$!
        # Detached from the harness's pipe on purpose. This subshell sleeps out
        # the `-k` grace period AFTER killing the child, so it outlives the
        # attempt; while it held the pipe's write end the reader blocked on it
        # and the file cost 67 seconds of wall clock instead of one.
        ( sleep "$budget"; kill -TERM "$child" 2>/dev/null; sleep "$k"; kill -KILL "$child" 2>/dev/null ) \
          >/dev/null 2>&1 </dev/null &
        watcher=$!
        wait "$child"; rc=$?
        kill "$watcher" 2>/dev/null
        # GNU timeout reports 124 on expiry; a killed child surfaces as 128+n.
        [ "$rc" -ge 128 ] && rc=124
        exit "$rc"
      SH

      # apt-get: stalls or answers on command, and counts how often it was asked.
      write_stub File.join(bin, "apt-get"), <<~SH
        n=$(( $(cat "#{apt_count}" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "#{apt_count}"
        case "#{mode}" in
          healthy) exit 0 ;;
          flaky)   [ "$n" -ge "#{ok_on}" ] && exit 0 ;;
        esac
        # The stall — far beyond the rewritten 1s budget.
        #
        # `exec`, AND the redirects, both matter, for one reason. REAL GNU
        # timeout runs its command in a NEW PROCESS GROUP and signals the whole
        # group, so in CI this process dies with the shell above it. The stub
        # above is simpler and signals only its direct child, so without `exec`
        # a stub shell survives here holding the harness's output pipe, and the
        # reader blocks on it: measured at 34s and 32s per stalling scenario,
        # 67s for the file. `exec` replaces this shell with the sleep, and the
        # redirects mean the sleep holds no copy of the pipe. Now under a second.
        #
        # The simplification is safe to make BECAUSE of that difference: the
        # stub leaking a grandchild is a stub artefact. Were it real, a survivor
        # would still hold /var/lib/dpkg/lock and the retry would be useless —
        # which is exactly why ci.yml must keep using timeout's default
        # (group-killing) behaviour and never pass --foreground.
        exec sleep 30 >/dev/null 2>&1 </dev/null
      SH

      write_stub File.join(bin, "dpkg"), <<~SH
        n=$(( $(cat "#{dpkg_count}" 2>/dev/null || echo 0) + 1 ))
        echo "$n" > "#{dpkg_count}"
        exit 0
      SH

      script = File.join(dir, "step.sh")
      File.write(script, "#!/bin/bash\n#{body}")
      FileUtils.chmod(0o755, script)

      output, status = capture_bounded(script, bin, dir)

      {
        status: status,
        output: output,
        apt_calls: File.exist?(apt_count) ? File.read(apt_count).to_i : 0,
        dpkg_calls: File.exist?(dpkg_count) ? File.read(dpkg_count).to_i : 0,
        timeout_calls: File.exist?(timeout_log) ? File.read(timeout_log).lines.map(&:strip) : []
      }
    end
  end

  # Runs the step with a Ruby-side deadline, killing the whole process group on
  # expiry. Without this, a run-body that lost its bound would HANG the suite
  # rather than fail it — the exact failure this file is about, reproduced one
  # level up.
  def capture_bounded(script, bin, dir)
    read, write = IO.pipe
    pid = Process.spawn(
      { "PATH" => "#{bin}:#{ENV['PATH']}", "HOME" => dir },
      script, out: write, err: write, pgroup: true
    )
    write.close

    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + HARNESS_DEADLINE
    done = nil
    until done
      done = Process.waitpid2(pid, Process::WNOHANG)
      break if done
      if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Process.kill("KILL", -Process.getpgid(pid)) rescue nil
        Process.waitpid2(pid) rescue nil
        flunk "the run-body did not finish within #{HARNESS_DEADLINE}s against a 1s budget — it is no " \
              "longer bounding its own fetch, which is the entire defect this file guards"
      end
      sleep 0.05
    end

    output = read.read
    read.close
    [ output, done[1].exitstatus ]
  end

  def write_stub(path, body)
    File.write(path, "#!/bin/bash\n#{body}")
    FileUtils.chmod(0o755, path)
  end
end
