# frozen_string_literal: true

# bin/lib/ship_wait.rb — the decision logic behind `bin/ship-wait`.
#
# ONE job: given the text of a ship LOG and one boolean saying whether the run
# has ENDED, return a verdict — `:succeeded`, `:failed`, or `:running`. Every
# rule that could be got wrong lives here as a pure function, so the guard can
# assert the rule directly instead of inferring it from a wall-clock.
#
# THE DEFECT THIS EXISTS TO KILL (task ship-wait-has-no-primitive, 2026-09-09).
# `bin/ship` runs ~12 minutes now that it waits for CI, the docs say "run it in
# the background", and there they stop. So every builder invents a watcher, and
# the obvious invention cannot fire:
#
#     while pgrep -f "bin/ship <slug>" >/dev/null; do sleep 30; done
#
# The loop's OWN command line contains the string it greps for. Measured across
# one session: one builder left 30+ orphaned shells this way and fell back to
# hand-polling for the rest of it; several woke repeatedly reporting "still
# pending". A watcher that can never fire is indistinguishable from a slow job,
# which is why nobody noticed.
#
# HOW IT ACTUALLY BITES ON macOS — measured 2026-09-09, because the folk
# explanation is half right and the half it gets wrong is the half that tells you
# how many shells you need to be in trouble. `pgrep(1)` here excludes **itself and
# its ancestors** by default (`-a` opts them back in), so a LONE watcher does not
# match the shell running its own loop, and it exits. The deadlock needs a
# SIBLING: a second watcher started while the first still runs, or a single
# orphan left behind by an earlier attempt. Then each shell's argv carries the
# pattern the other greps for, both conditions are true forever, and neither can
# ever exit — with `bin/ship` not running at all. Reproduced with two concurrent
# shells: both reported the condition still TRUE after six polls against no ship.
# That is why the orphan count in the report is not incidental colour. It is the
# fuel: the first watcher a session starts looks like it works, and every one
# after it is immortal.
#
# SO THIS FAMILY NEVER TOUCHES THE PROCESS TABLE BY PATTERN. Liveness comes from
# a PID captured at launch (`Process.kill(0, pid)`) or from a sentinel the
# launcher appends to the log — never from `pgrep`/`pkill`/`ps | grep`. A pattern
# that can match a sibling is the whole disease.
#
# AND ENDED IS NOT FAILED. `bin/ship` can exit 0 on a run that did not reach the
# seam, so process absence proves nothing about OUTCOME. The authoritative fact is
# a line ship prints only after its own end-to-end read-back verify:
#
#     stage: submitted (read back verified)
#
# `verdict` therefore reads the LOG for WHAT happened and takes `ended:` only as
# WHEN to stop waiting. An exit status is never consulted for the verdict — it is
# relayed to the reader and nothing more.
module ShipWait
  # bin/ship's final stdout line, printed only after the read-back verify passes
  # (bin/ship's last `puts`). The one string that means "this ship reached the
  # submitted seam". Nothing else in ship's output is terminal-and-positive.
  SUCCESS_LINE = "stage: submitted (read back verified)"

  # The marker `bin/ship-wait --launch` appends to the log after the ship process
  # exits. It makes the LOG self-sufficient: a wait attaching later — a new
  # session, a re-run after the harness killed the first watcher — reads a
  # terminal state without needing the process to still exist, or a PID at all.
  SENTINEL_PREFIX = "ship-wait: ship exited status="
  SENTINEL_RE = /^ship-wait: ship exited status=(-?\d+)\s*$/

  # Exit codes. The caller branches on these WITHOUT re-parsing the log.
  EXIT_SUCCEEDED = 0   # the log carries SUCCESS_LINE
  EXIT_FAILED    = 1   # the run ENDED without it
  EXIT_TIMEOUT   = 2   # still running when the bound elapsed
  EXIT_USAGE     = 3   # bad invocation
  EXIT_NO_LOG    = 4   # nothing to watch: no log, and no --launch

  # ~12 min is a cold ship; 30 gives headroom for a slow CI without ever being
  # unbounded. A wait that can hang forever recreates the defect in a new shape.
  DEFAULT_TIMEOUT_S = 1800
  DEFAULT_INTERVAL_S = 10
  # A spin loop burns a stat(2) per iteration for nothing. One second is already
  # far finer than a 12-minute job needs.
  MIN_INTERVAL_S = 1

  module_function

  # Did this ship reach the seam? Exact-line, not a substring: the phrase also
  # appears in bin/ship's own header comment and in these docs, and a watcher
  # that greps its own documentation is the same class of bug as one that greps
  # its own command line.
  def succeeded?(text)
    text.to_s.each_line.any? { |line| line.strip == SUCCESS_LINE }
  end

  # The status the launcher recorded, or nil when the log holds no sentinel.
  # LAST sentinel wins — a truncate-on-relaunch should make this moot, but a log
  # appended to twice must still report the run that finished most recently.
  def sentinel_status(text)
    match = nil
    text.to_s.each_line { |line| match = Regexp.last_match(1) if line =~ SENTINEL_RE }
    match&.to_i
  end

  # Has the RUN ended, as far as the log alone can say?
  def exited?(text)
    !sentinel_status(text).nil?
  end

  # THE RULE. `ended:` answers WHEN (sentinel, or a captured PID that is gone);
  # the log answers WHAT.
  #
  # Order matters and is the point: SUCCESS_LINE wins over every ending, so a
  # ship that printed the line and then exited non-zero — or exited 0 having
  # printed nothing — is judged on what it PRINTED. `ended` alone is never
  # evidence of success, only of "stop waiting".
  def verdict(text, ended: false)
    return :succeeded if succeeded?(text)
    return :failed if ended || exited?(text)

    :running
  end

  def exit_code(verdict)
    case verdict
    when :succeeded then EXIT_SUCCEEDED
    when :failed    then EXIT_FAILED
    else                 EXIT_TIMEOUT
    end
  end

  # Liveness of a CAPTURED pid — signal 0, never a pattern. EPERM means the
  # process exists and is not ours, which is still "alive".
  def alive?(pid)
    pid = pid.to_i
    return false unless pid.positive?

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  rescue Errno::EPERM
    true
  rescue StandardError
    false
  end

  # The last thing ship said — its own `ship: …` warn line (both `die!` and
  # `say` use that prefix, so this is a POINTER to the log, never a verdict).
  # Falls back to the last non-blank line so a crash outside ship's own error
  # path still reports something the reader can act on.
  def last_report(text)
    lines = text.to_s.each_line.map(&:rstrip).reject(&:empty?)
    lines.reverse.find { |line| line.start_with?("ship: ") } || lines.last
  end

  # State-file names. Namespaced by SLUG, always — sibling agents share a
  # scratchpad and a bare `ship.log` has already had two ships truncate each
  # other (2026-09-01, docs/agents/modules/worktrees.md).
  def log_path(dir, slug) = File.join(dir, "ship-#{slug}.log")
  def pid_path(dir, slug) = File.join(dir, "ship-#{slug}.pid")
  def previous_log_path(dir, slug) = File.join(dir, "ship-#{slug}.log.prev")

  def clamp_interval(seconds)
    value = seconds.to_f
    value < MIN_INTERVAL_S ? MIN_INTERVAL_S.to_f : value
  end
end
