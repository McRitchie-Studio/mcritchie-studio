# frozen_string_literal: true

require "json"
require "set"
require_relative "session_markers"
require_relative "agent_presence"
require_relative "process_table"

# MarkerPrune — the session-marker pruner `bin/release archive` drives.
#
# The narration store (<projects>/.agents/sessions, owned by SessionMarkers) gains a
# handful of files per session and nothing ever removed them. This removes the
# markers of sessions that are over: every marker of a session goes, or none does.
#
# A SESSION IS KEPT, WITH EVERY MARKER IT HOLDS, when any of these is true:
#
#   * it is THIS session (the one running the prune);
#   * any of its markers was touched inside the window. The newest mtime is taken
#     across EVERY marker, the statusline throttles included: a terminal still
#     painting is reason enough to keep, and a renewing lease touches its claim
#     marker, so a live peer's lease keeps its session by construction;
#   * a presence claim it holds grades live or unverifiable against the process
#     table, the same grading bin/agent-presence prints;
#   * a renewer pid file it holds names a running process;
#   * a desk on this machine names it in its .agent-context.json (session_id or
#     parent_session_id).
#
# The rule is per session rather than per file so that an old marker of a session
# that is still working (its `.json`, written once at start) is never taken from it.
#
# FAIL CLOSED: without a process table nothing can be graded, so the plan refuses
# and prunes nothing.
#
# The window is MARKER_PRUNE_WINDOW_DAYS (default 7), or --days on the CLI.
module MarkerPrune
  DEFAULT_WINDOW_DAYS = 7
  WINDOW_ENV = "MARKER_PRUNE_WINDOW_DAYS"
  SAMPLE_SIZE = 20
  SUMMARY_TAG = "MARKER_PRUNE_SUMMARY"

  UUID_PREFIX = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i
  RENEWER = /renewer/

  Plan = Struct.new(:prune, :kept_sessions, :pruned_sessions, :refusal, keyword_init: true) do
    def names = prune.map { |e| e[:name] }
  end

  module_function

  def window_days(env = ENV, override = nil)
    raw = override || env[WINDOW_ENV]
    value = raw && Float(raw, exception: false)
    value&.positive? ? value : DEFAULT_WINDOW_DAYS
  end

  # The session a marker belongs to. Ids are UUIDs (Claude and Codex both), and
  # some writers glue a suffix straight on with no dot
  # (`<uuid>build-claim-renewer-<slug>`), so the UUID prefix wins when there is
  # one; otherwise the stem before the first dot.
  def session_id_of(name)
    name = name.to_s
    return name[UUID_PREFIX] if name.match?(UUID_PREFIX)

    name.split(".", 2).first.to_s
  end

  # PURE. +entries+ are SessionMarkers.entries rows ({name:, mtime:}); the live
  # sets are computed by the caller (+live_inputs+). Returns a Plan.
  def plan(entries:, now:, window_days:, current_session_id:, live_session_ids:, desk_session_ids:)
    cutoff = now - (window_days * 86_400)
    protected = Set.new([current_session_id.to_s].reject(&:empty?)) | live_session_ids.to_a | desk_session_ids.to_a

    by_session = entries.group_by { |e| session_id_of(e[:name]) }
    prune = []
    kept = []
    pruned = []
    by_session.each do |sid, rows|
      newest = rows.map { |r| r[:mtime] }.compact.max
      if sid.empty? || protected.include?(sid) || newest.nil? || newest >= cutoff
        kept << sid
      else
        pruned << sid
        prune.concat(rows)
      end
    end
    Plan.new(prune: prune.sort_by { |e| e[:name] }, kept_sessions: kept.sort, pruned_sessions: pruned.sort, refusal: nil)
  end

  # The live inputs, read from this machine. Returns [live_session_ids, refusal].
  def live_session_ids(projects_dir, entries, table:)
    return [Set.new, "no process table (ps unavailable), so no claim can be graded; nothing is pruned"] if table.empty?

    live = Set.new
    AgentPresence.claims(root: projects_dir, table: table).each do |claim|
      next unless AgentPresence::COUNTED_GRADES.include?(claim[:grade])

      live << session_id_of(File.basename(claim[:path].to_s))
    end
    entries.each do |e|
      next unless e[:name].match?(RENEWER)

      sid = session_id_of(e[:name])
      raw = SessionMarkers.read("", projects_dir, e[:name]).to_s
      pid = ProcessTable.coerce_pid(raw.split(/\s+/).first)
      live << sid if pid && ProcessTable.live_process(table, pid)
    end
    [live, nil]
  end

  # Session ids every desk on this machine is bound to.
  def desk_session_ids(projects_dir)
    Dir.glob(File.join(projects_dir.to_s, "*", ".worktrees", "*", ".agent-context.json")).each_with_object(Set.new) do |path, ids|
      ctx = JSON.parse(File.read(path))
      [ctx["session_id"], ctx["parent_session_id"]].each { |id| ids << id.to_s unless id.to_s.strip.empty? }
    rescue StandardError
      next
    end
  end

  # Remove the planned markers. Each delete passes the SessionMarkers choke point.
  # Returns the names actually removed.
  def apply!(plan, projects_dir, env: ENV, state_dir: TaskUsageSandbox.real_state_dir)
    plan.prune.filter_map do |e|
      e[:name] if SessionMarkers.delete_entry(e[:name], projects_dir, env: env, state_dir: state_dir)
    end
  end

  def summary(plan, applied:, removed: nil)
    {
      pruner: "session-markers",
      applied: applied,
      count: applied ? removed.to_a.size : plan.prune.size,
      sessions: plan.pruned_sessions.size,
      kept_sessions: plan.kept_sessions.size,
      sample: (applied ? removed.to_a : plan.names).first(SAMPLE_SIZE),
      refusal: plan.refusal
    }
  end

  def summary_line(summary) = "#{SUMMARY_TAG} #{JSON.generate(summary)}"

  def parse_summary(output)
    line = output.to_s.lines.reverse.find { |l| l.start_with?("#{SUMMARY_TAG} ") }
    line && JSON.parse(line.delete_prefix("#{SUMMARY_TAG} "), symbolize_names: true)
  rescue JSON::ParserError
    nil
  end
end
