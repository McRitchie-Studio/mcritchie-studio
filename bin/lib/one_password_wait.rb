# frozen_string_literal: true

require_relative "op_meter"
require_relative "op_vaults"

# OnePasswordWait — `bin/release prepare|ship --wait-for-1password[=MINUTES]`.
#
# WHY. Three times on 2026-10-27/28 the 1Password app stopped answering: every
# `op` read hung until it was killed, the release step failed on an empty
# credential, and an app restart or a reboot fixed it some time later. The step
# was resumed each time by a hand-built watcher that tried a read every two
# minutes and re-ran the step once one answered. This is that watcher, opt-in.
#
# HOW. The step runs as a child process (the same `bin/release <step> ...` line,
# minus the flag). When it exits non-zero, one bounded probe read asks whether
# 1Password is hung. If it answered (or failed some other way: signed out, no
# grant), the step's own failure stands and its exit status is returned: the
# wait never hides a real error. If it hung, the probe repeats every
# POLL_SECONDS, saying so each time, until a read answers (then the step runs
# again; prepare and ship both resume on a re-run) or the deadline passes (then
# it gives up, exit OpMeter::HUNG_EXIT).
#
# THE PROBE reads the agent GitHub App's `app-id` field: the read the release
# makes first and the one that hung, and a field that is not a secret. The value
# is discarded and never printed. The read is bounded like every other
# (OpMeter.popen: two attempts under thirty seconds, process-group kill), so a
# hung probe costs no 1Password quota: it never reached the server.
#
# Every collaborator is injectable (run_step, probe, sleeper, clock, out), so the
# loop is proven with a fake `op` on PATH and a fake clock, never a real wait.
module OnePasswordWait
  FLAG = "--wait-for-1password"
  POLL_SECONDS = 120
  DEFAULT_MINUTES = 60
  PROBE_ITEM = "github.mcritchie-agent"
  PROBE_FIELD = "app-id"

  class BadMinutes < ArgumentError; end

  module_function

  # Removes the flag from +args+. nil when absent; the minutes when present
  # (DEFAULT_MINUTES for the bare form). Never takes the NEXT token as its value:
  # only `--wait-for-1password=MINUTES` carries one, so a following slug or flag
  # is never swallowed.
  def take!(args)
    index = args.index { |a| a.to_s == FLAG || a.to_s.start_with?("#{FLAG}=") }
    return nil unless index

    token = args.delete_at(index).to_s
    return DEFAULT_MINUTES if token == FLAG

    value = token.split("=", 2).last
    minutes = Integer(value, 10, exception: false)
    raise BadMinutes, "#{FLAG}=#{value}: MINUTES must be a whole number above zero" unless minutes&.positive?

    minutes
  end

  # :answering, :hung, or :failed (op answered with an error: not a hang).
  def probe(env: ENV, op_bin: nil)
    bin = op_bin || env["OP_WAIT_OP_BIN"].to_s.then { |b| b.empty? ? "op" : b }
    OpMeter.popen(OpVaults.op_env, [bin, "read", OpVaults.ref(PROBE_ITEM, PROBE_FIELD)],
                  via: "wait-for-1password", env: env, announce: false, err: File::NULL)
    return :hung if OpMeter.last_hung?

    $?.success? ? :answering : :failed
  rescue SystemCallError
    :failed
  end

  # Runs the step until it succeeds, fails for a reason that is not a hung
  # 1Password, or the wait runs out. Returns the exit status to leave with.
  def supervise(step:, minutes:, run_step:, probe: -> { self.probe }, sleeper: ->(s) { Kernel.sleep(s) },
                clock: -> { Time.now }, out: $stderr)
    deadline = clock.call + (minutes * 60)
    loop do
      status = run_step.call
      return status if status.zero?
      return status unless probe.call == :hung

      out.puts("✗ #{OpMeter::HUNG_LINE}")
      out.puts("  #{FLAG}: `bin/release #{step}` stopped on it. Trying a read every " \
               "#{POLL_SECONDS / 60} minutes until #{stamp(deadline)}, then resuming the step.")
      return OpMeter::HUNG_EXIT unless wait_for_answer(deadline, probe, sleeper, clock, out, step, minutes)

      out.puts("  #{FLAG}: 1Password answered at #{stamp(clock.call)}. Resuming `bin/release #{step}`.")
    end
  end

  # true once a probe answers; false at the deadline.
  def wait_for_answer(deadline, probe, sleeper, clock, out, step, minutes)
    loop do
      left = deadline - clock.call
      if left <= 0
        out.puts("✗ #{FLAG}: 1Password still not answering after #{minutes} minutes; gave up at " \
                 "#{stamp(clock.call)}. Quit and reopen the 1Password app (reboot if that fails), " \
                 "then re-run `bin/release #{step}`: it resumes.")
        return false
      end
      sleeper.call([POLL_SECONDS, left].min)
      return true unless probe.call == :hung

      out.puts("  #{FLAG}: still not answering at #{stamp(clock.call)}.")
    end
  end

  # Denver wall-clock time, as the operator reads it.
  def stamp(time)
    saved = ENV["TZ"]
    ENV["TZ"] = "America/Denver"
    time.localtime.strftime("%H:%M %Z")
  ensure
    ENV["TZ"] = saved
  end
end
