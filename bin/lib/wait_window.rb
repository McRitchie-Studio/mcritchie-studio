# frozen_string_literal: true

# bin/lib/wait_window.rb — the decision logic behind `bin/task wait-window`.
#
# THE OPERATOR-WINDOW WAIT (docs/agents/system/devops-v3-design.md section 6).
# A session that escalated a block to Alex, or asked him to look at a demo, has
# one question: has he answered, or has the window lapsed so the default applies?
# This module answers it from the task API's DERIVED `windows` list
# (Task#operator_windows) — the board's clock and config decide; the CLI holds no
# window math and reads no YAML, so a changed length in config/release_builder.yml
# moves this wait without a deploy of the tooling.
#
# ANSWERED means the list is EMPTY: the `Escalated:` block was cleared, or the
# approval request left `waiting` (approved, changes requested, or settled). It
# does not read the answer's content — that is the caller's next read.
#
# BOUNDED BY CONSTRUCTION. The loop's deadline is the LATEST open end plus the
# grace, recomputed on every read, so a wait can never outlive the window it
# watches (the ship-wait family's rule: a watcher that can hang forever is the
# defect in a new shape). A read that fails is not an answer: three consecutive
# failures exit 1 rather than reading "no windows" into a broken board.
#
# Injected clock/sleeper/reader so every firing condition is unit-tested without
# a wall clock (test/lib/wait_window_test.rb); the end-to-end wire is pinned by
# test/lib/wait_window_cli_test.rb against a stub board.
require "json"
require "time"

module WaitWindow
  EXIT_ANSWERED     = 0 # the window closed: block cleared / approval answered (or nothing was open)
  EXIT_READ_FAILURE = 1 # the board could not be read (three consecutive failures, or the task is gone)
  EXIT_LAPSED       = 2 # the latest window end plus the grace passed with a window still open
  EXIT_USAGE        = 3

  DEFAULT_INTERVAL_S = 15
  DEFAULT_GRACE_S    = 60
  MIN_INTERVAL_S     = 1
  MAX_CONSECUTIVE_READ_FAILURES = 3

  USAGE = "usage: bin/task wait-window <slug> [--interval SECONDS] [--grace SECONDS] [--json]"

  class UsageError < StandardError; end

  Options = Struct.new(:slug, :interval, :grace, :json, keyword_init: true)

  module_function

  def parse_args(argv)
    args = Array(argv).dup
    opts = Options.new(slug: nil, interval: DEFAULT_INTERVAL_S, grace: DEFAULT_GRACE_S, json: false)
    until args.empty?
      arg = args.shift
      case arg
      when "--interval" then opts.interval = seconds!(arg, args.shift, min: MIN_INTERVAL_S)
      when "--grace"    then opts.grace = seconds!(arg, args.shift, min: 0)
      when "--json"     then opts.json = true
      when "--help", "-h" then raise UsageError, USAGE
      when /\A-/ then raise UsageError, "unknown flag #{arg}\n#{USAGE}"
      else
        raise UsageError, "unexpected argument #{arg.inspect}\n#{USAGE}" if opts.slug

        opts.slug = arg
      end
    end
    raise UsageError, USAGE if opts.slug.to_s.strip.empty?

    opts
  end

  def seconds!(flag, raw, min:)
    value = Integer(raw.to_s, exception: false)
    raise UsageError, "#{flag} needs a whole number of seconds (>= #{min})\n#{USAGE}" if value.nil? || value < min

    value
  end

  # The open windows on a task-API payload — each a hash with at least `kind`
  # and an ISO `ends_at`. Anything else is not a window and is ignored.
  def windows(task)
    list = task.is_a?(Hash) ? task["windows"] : nil
    Array(list).select { |w| w.is_a?(Hash) && ends_at(w) }
  end

  def ends_at(window)
    Time.iso8601(window["ends_at"].to_s)
  rescue ArgumentError
    nil
  end

  # When the wait stops asking: the latest end among the open windows plus the
  # grace. nil when nothing is open.
  def deadline(open_windows, grace:)
    ends = open_windows.filter_map { |w| ends_at(w) }
    return nil if ends.empty?

    ends.max + grace
  end

  def describe(window, now)
    ends = ends_at(window)
    left = [(ends - now).ceil, 0].max
    state = now >= ends ? "lapsed" : format("%02d:%02d left", left / 60, left % 60)
    "#{window['kind']} #{state} (ends #{ends.utc.iso8601})"
  end

  # The facts the final line reports beside the verdict.
  def facts(task)
    devops = task.is_a?(Hash) ? (task.dig("metadata", "devops") || {}) : {}
    blocked = task.is_a?(Hash) && !task["blocked_at"].to_s.empty? && task["stage"].to_s == "building"
    {
      "approval_status" => devops["approval_status"].to_s.empty? ? "none" : devops["approval_status"].to_s,
      "blocked" => blocked,
      "block_kind" => (task["block_kind"] if blocked)
    }
  end

  # Poll until answered / lapsed / unreadable. Returns the exit code; prints one
  # line per read to `out` and read failures to `err`; with `json:` the verdict
  # is also emitted as one JSON line on `out` for a script to parse.
  def run(slug:, reader:, sleeper:, clock:, interval:, grace:, out:, err:, json: false)
    failures = 0
    at_start = nil
    loop do
      task = reader.call
      now = clock.call

      if task == :not_found
        err.puts("wait-window #{slug}: task not found on the board")
        emit(json, out, "verdict" => "read_failure", "slug" => slug, "reason" => "task not found")
        return EXIT_READ_FAILURE
      end

      if task.nil?
        failures += 1
        err.puts("wait-window #{slug}: board read failed (#{failures}/#{MAX_CONSECUTIVE_READ_FAILURES})")
        if failures >= MAX_CONSECUTIVE_READ_FAILURES
          emit(json, out, "verdict" => "read_failure", "slug" => slug,
                          "reason" => "#{failures} consecutive read failures")
          return EXIT_READ_FAILURE
        end
        sleeper.call(interval)
        next
      end

      failures = 0
      open = windows(task)
      at_start ||= open

      if open.empty?
        detail = at_start.empty? ? "no window was open" : "#{at_start.map { |w| w['kind'] }.uniq.join(' + ')} window closed"
        out.puts("wait-window #{slug}: answered — #{detail} · #{facts_line(task)}")
        emit(json, out, { "verdict" => "answered", "slug" => slug, "windows_at_start" => at_start }.merge(facts(task)))
        return EXIT_ANSWERED
      end

      deadline = deadline(open, grace: grace)
      if now >= deadline
        out.puts("wait-window #{slug}: lapsed — #{open.map { |w| describe(w, now) }.join(' · ')}; " \
                 "#{grace}s grace passed with it still open · #{facts_line(task)}")
        emit(json, out, { "verdict" => "lapsed", "slug" => slug, "windows" => open }.merge(facts(task)))
        return EXIT_LAPSED
      end

      out.puts("wait-window #{slug}: #{open.map { |w| describe(w, now) }.join(' · ')}")
      sleeper.call([interval, [(deadline - now).ceil, MIN_INTERVAL_S].max].min)
    end
  end

  def facts_line(task)
    f = facts(task)
    block = f["blocked"] ? "blocked (#{f['block_kind'] || 'unknown kind'})" : "not blocked"
    "approval_status #{f['approval_status']} · #{block}"
  end

  def emit(json, out, payload)
    out.puts(JSON.generate(payload)) if json
  end
end
