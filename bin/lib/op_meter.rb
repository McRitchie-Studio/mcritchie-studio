# frozen_string_literal: true

require "English"
require "time"
require "fileutils"
require_relative "projects_root"

# THE SANDBOX GUARD IS OPTIONAL AT LOAD TIME, and that is a hard requirement
# rather than defensiveness. This file lives in bin/lib but the guard lives in
# lib/, one directory OUTSIDE the bin/ tree — and the bin/ tree travels on its
# own: bin/session-preflight is run from a HUB checkout against an unrelated
# --root, and test/commands/session_preflight_test.rb copies only `hub/bin` to a
# temp root and asserts the helpers still resolve there.
#
# MEASURED on PR #1113: a plain `require_relative "../../lib/task_usage_sandbox"`
# here raised LoadError in that relocated tree — and because bin/lib/task_board.rb
# requires this file, it took the ENTIRE BOARD CLI down with it. Telemetry that
# can break the thing it measures is worse than no telemetry; that is the same
# constraint as "must not break when `op` is absent", one layer up, and it must
# hold at LOAD time and not merely at call time.
#
# FAIL CLOSED, not open: when the guard is unreachable this meter REFUSES to
# write at all (see #refused?). Nothing here re-implements the guard's rules — a
# second copy of a safety rule is how the two halves drift apart — so a tree
# without the guard simply records nothing.

# OpMeter — WHO SPENT THE 1PASSWORD QUOTA. Every `op` invocation the bin/ stack
# makes is recorded here: the calling command, the action, the outcome, a
# timestamp. Nothing else in the ecosystem records it, and that absence is the
# defect this closes.
#
# WHY THIS EXISTS (measured, 2026-08-31, and this is the SECOND time). The
# account-wide 1Password quota showed 247 read_writes consumed between 08:15 and
# 11:15 and nobody could say what spent them. The reconstruction had to be done
# by measurement, and it came up EMPTY — bin/task: 0 reads, two authenticated git
# ops: 0 reads, steady state: 0. (Every read observed while monitoring was the
# MONITORING COMMAND: `op service-account ratelimit` itself costs a read. Worth
# knowing before instrumenting anything here.) The spend was bursty, concentrated
# across twelve review subagents plus their merges and ships — roughly 20 reads
# per agent, all unattributed.
#
# THE POINT IS THAT THIS IS NOT A NEW DIAGNOSIS. bin/gh-app-git-credential
# already carries a comment saying three reads per push/fetch/repo was "the
# reason a day of ordinary work spent the account's quota". It was found once,
# fixed once, and became un-findable again because nothing logged it. A finding
# that has to be re-derived from scratch every time is not a finding. So the
# answer moves from an investigation to a query: `bin/op-reads`.
#
# ── TWO CONSTRAINTS THAT OUTRANK THE FEATURE ──────────────────────────────────
#
# 1. THIS MUST NOT ITSELF COST A READ. An instrument that consumes the thing it
#    measures is worse than none. Nothing in this file executes `op`, opens a
#    socket, or shells out — it appends a line to a local file. Proven by
#    test/lib/op_meter_test.rb, which runs the whole path with a recording `op`
#    stub and asserts the stub was executed ZERO times.
#
# 2. IT MUST NOT BREAK WHEN op IS RATE-LIMITED OR ABSENT. Every consumer has a
#    working fallback today — the ecosystem ran a full-day 1Password outage on
#    those fallbacks — and metering may not cost them that. So `record` NEVER
#    raises and NEVER changes `$?`: every StandardError a full disk, a read-only
#    filesystem or a vanished directory can raise is swallowed, and it returns
#    nil. A log we failed to write is a worse log; a push we failed to make is an
#    outage.
#
#    The rescue is StandardError and NOT Exception ON PURPOSE. TaskUsageSandbox
#    signals a rule-2 violation with `abort` — a SystemExit, deliberately outside
#    StandardError precisely so best-effort callers like this one cannot degrade
#    it into a no-op. Widening to Exception here would re-open the hole the guard
#    was built to close, and it would do it silently.
#
# ── WHY `$?` SURVIVES ──────────────────────────────────────────────────────────
# `popen` records AFTER the child is reaped, and every caller reads `$?` after it
# returns (`$?.success? ? out : ""`). File IO spawns no process, so `$?` still
# holds the `op` child's status when the caller looks. That is load-bearing, not
# incidental: a `record` that shelled out for its timestamp would silently turn
# every failed read into a successful one.
#
# ── THE SANDBOX POSTURE, AND WHY IT DIFFERS PER RULE ───────────────────────────
# This is a state store under the operator's real <projects>/.agents, so it
# answers to TaskUsageSandbox — but the two rules get OPPOSITE responses here,
# and the split is deliberate:
#
#   RULE 1 (armed + unpinned)  → SKIP, quietly-ish. This is the routine test
#     condition: test/lib/task_board_test.rb drives the whole secret chain
#     IN-PROCESS with an `op` stub and pins nothing, because it has no store of
#     its own to pin. Aborting there would take the suite down over telemetry.
#     bin/statusline made the same call for the same reason (a best-effort
#     writer fails the WRITE, never the caller).
#   RULE 2 (pinned back INSIDE the real store) → ABORT, via enforce!. That is not
#     a routine condition, it is a misconfiguration, and it is the rule that makes
#     the guarantee a property of the PATH rather than of the configuration.
#
# So `refused?` answers rule 1 and returns early; `append` then reaches
# enforce!, which is left holding exactly rule 2. Neither check is dead.
module OpMeter
  # Scoped to OpMeter, NOT to Object. Defining it at file scope (the first
  # attempt) leaked a bare SANDBOX_AVAILABLE onto Object for every process that
  # loads the board CLI, and `OpMeter::SANDBOX_AVAILABLE` then raised NameError —
  # a constant that is both too public and unreachable at once.
  SANDBOX_AVAILABLE = begin
    require_relative "../../lib/task_usage_sandbox"
    true
  rescue LoadError
    false
  end

  STORE = "op-reads"

  # The env vars that can LOCATE this log — mirrored in TaskUsageSandbox::STORES.
  # Either one is enough to steer the path off the operator's real root, which is
  # all rule 1 defends.
  PINS = %w[MCR_OP_READS_LOG CLAUDE_PROJECTS_DIR].freeze

  # TAB-separated, because the fields are machine-written and a TSV row cannot be
  # mangled by a quote in a value the way ad-hoc JSON from shell can. The bash
  # half (bin/lib/op-meter.sh) writes the SAME seven columns in the same order —
  # they are one format with two writers, and bin/op-reads parses both.
  FIELDS = %i[ts caller action outcome via pid context].freeze
  FIELD_NAMES = FIELDS.map(&:to_s).freeze

  # A field that is absent. Never blank: a blank column is indistinguishable from
  # a truncated row, and this log's whole job is to be readable a month later.
  BLANK = "-"

  module_function

  # Record one `op` invocation. Best-effort by contract: returns nil, always.
  #
  # +action+  the op subcommand as invoked — "read", "item get", "vault list",
  #           "whoami", "signin". Recorded as given so the log answers "which KIND
  #           of call", which is the axis that maps onto the quota.
  # +outcome+ "ok" or "fail:<status>".
  # +via+     the library seam that made the call (agent_api, task_board,
  #           gh-token). The CALLER is taken from $PROGRAM_NAME, so a read made by
  #           bin/lib/agent_api.rb on behalf of bin/task is attributed to `task` —
  #           which is the question being asked. `via` keeps the seam without
  #           losing the command.
  def record(action:, outcome:, via: nil, env: ENV)
    return nil if refused?(env)

    append(action, outcome, via, env)
    nil
  rescue StandardError
    nil
  end

  # Run `op` and record it. The ONE seam the Ruby callers use, so a new call site
  # cannot forget to meter: it gets metering by using the wrapper at all.
  #
  # Mirrors IO.popen(env, argv, **opts, &:read) — the exact shape all three Ruby
  # call sites already used — and returns the child's stdout unchanged.
  def popen(op_env, argv, via:, env: ENV, **opts)
    out = IO.popen(op_env, argv, **opts, &:read).to_s
    record(action: action_for(argv), outcome: outcome_for($CHILD_STATUS), via: via, env: env)
    out
  rescue SystemCallError => e
    # `op` is ABSENT or unexecutable, so NO quota was spent — but the ATTEMPT is
    # still the thing attribution is about, and a run that shows nothing at all
    # is indistinguishable from a run that was never metered. Recorded with the
    # SHELL's vocabulary (127 not found, 126 not executable) because the bash
    # half reports exactly those numbers for the same two conditions, and one
    # log with two vocabularies is a log nobody can total.
    record(action: action_for(argv), outcome: spawn_failure(e), via: via, env: env)
    raise
  end

  # Re-raising above is load-bearing: every caller already has a rescue and a
  # working fallback for an absent `op` (that is what the ecosystem ran on
  # through a full-day 1Password outage). Metering may observe that path; it may
  # not change it.
  def spawn_failure(error)
    return "fail:126" if error.is_a?(Errno::EACCES)

    "fail:127"
  end

  # "item get" and "vault list" are two words; "read" and "whoami" are one. The
  # log records what was ASKED FOR, so `op item get` must not flatten to `item`.
  def action_for(argv)
    parts = Array(argv).drop(1).reject { |a| a.to_s.start_with?("-") }
    return BLANK if parts.empty?
    return parts.first.to_s if parts.length == 1

    # A subcommand's own subcommand is a bare word; its OPERAND (a reference, an
    # item name) is not something to put in the log.
    second = parts[1].to_s
    second =~ /\A[a-z][a-z-]*\z/ ? "#{parts.first} #{second}" : parts.first.to_s
  end

  def outcome_for(status)
    return "fail:?" if status.nil?
    return "ok" if status.success?

    "fail:#{status.exitstatus || '?'}"
  end

  # Every recorded row, newest last, as hashes keyed by FIELDS AS STRINGS. String
  # keys and not symbols: these rows go straight to JSON for bin/op-reads --json,
  # and a symbol key would round-trip to a string there anyway — one vocabulary
  # for the row, whichever side of the CLI you read it from.
  # the log does not exist yet — "nothing has been recorded" and "the file is
  # missing" are the same answer to the only question anyone asks of it.
  #
  # READ-ONLY. bin/op-reads queries through here so it never has to resolve the
  # store itself; `append` stays the only writer in the ecosystem.
  def records(env: ENV)
    path = log_path(env)
    return [] unless File.file?(path)

    File.readlines(path).filter_map do |line|
      row = line.chomp.split("\t")
      next if row.length < FIELDS.length

      FIELD_NAMES.zip(row).to_h
    end
  rescue SystemCallError
    []
  end

  # Rule 1 only — see the posture note in the header. Deliberately does NOT touch
  # log_path: the guard's question here is about the ENV, not the path, and
  # keeping the path out of this method is what lets `append` stay the single
  # laundered seam.
  def refused?(env)
    # No guard on this tree (a relocated bin/ — see the header) → nothing can
    # prove the destination is safe, so write nothing. This also keeps `append`
    # unreachable without the guard, which is why it may name enforce! directly.
    return true unless SANDBOX_AVAILABLE

    guard = TaskUsageSandbox.guard_env(env)
    return false unless TaskUsageSandbox.active?(guard)

    PINS.none? { |pin| !guard[pin].to_s.strip.empty? }
  end

  # THE ONE WRITE SEAM. enforce! is handed the path, so rule 2 aborts a run that
  # pinned itself back inside the operator's real store.
  #
  # Opened in append mode per call rather than held open: these writers are
  # short-lived CLIs, several can run at once, and an O_APPEND write of one short
  # line is atomic enough on every filesystem this stack runs on. A shared handle
  # would buy nothing and lose rows when a process is killed mid-op — which is
  # exactly when you most want the row.
  def append(action, outcome, via, env)
    path = TaskUsageSandbox.enforce!(log_path(env), store: STORE,
                                                    env: TaskUsageSandbox.guard_env(env))
    FileUtils.mkdir_p(File.dirname(path))
    File.open(path, "a") { |f| f.write("#{row(action, outcome, via, env).join("\t")}\n") }
  end

  def row(action, outcome, via, env)
    [
      Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
      clean(File.basename($PROGRAM_NAME.to_s)),
      clean(action),
      clean(outcome),
      clean(via),
      Process.pid.to_s,
      clean(context(env))
    ]
  end

  # An opt-in tag for a burst — export MCR_OP_METER_CONTEXT before fanning out
  # subagents and the log tells you WHICH fan-out spent the quota, not just which
  # command. Falls back to the session id when the harness sets one. Both are ENV
  # lookups: no subprocess, no file read, nothing that could cost a read.
  def context(env)
    %w[MCR_OP_METER_CONTEXT CLAUDE_CODE_SESSION_ID].each do |key|
      value = env[key].to_s.strip
      return value unless value.empty?
    end
    BLANK
  end

  # A value can never break the row grammar. Tabs and newlines are the only
  # characters that could, so they are the only ones replaced.
  def clean(value)
    text = value.to_s.tr("\t\r\n", "   ").strip
    text.empty? ? BLANK : text
  end

  def log_path(env = ENV)
    override = env["MCR_OP_READS_LOG"].to_s.strip
    return File.expand_path(override) unless override.empty?

    projects = env["CLAUDE_PROJECTS_DIR"].to_s.strip
    projects = ProjectsRoot.default_projects_dir if projects.empty?
    File.join(File.expand_path(projects), ".agents", "op-reads.log")
  end

  # PRIVATE, and LAYER 2a of test/lib/state_store_containment_test.rb asserts it:
  # a shared lib that EXPORTS a raw store path lets a caller mutate the store
  # without ever naming .agents, which no source scan could see. `records` is the
  # exported read; `append` is the exported write, and it launders.
  private_class_method :log_path
end
