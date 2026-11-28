# /devops/sessions — every agent session of the last WINDOW, one row each, so
# Alex McRitchie can chase down the sessions that never ran /wrap. There is no
# Session table: a session is the session_id its narration (AgentActivity), its
# drawn Pokémon (SessionMascot) and its board tasks (Task) share, so this reads
# those three in one grouped query each.
#
# "Wrapped" is what the /wrap ritual leaves on the board: it seals the session's
# last open span with `bin/agent-activity close-open --outcome "session wrapped"`.
# The SessionEnd hook seals with "session ended", which is not a wrap. A wrap run
# while no span was open stamps nothing, so a few real wraps read as unwrapped.
#
# No prompt text reaches this page: the goal column is the session's own
# narration (its first and latest activity reason).
class SessionRoster
  WINDOW = 60.days
  WRAP_OUTCOME = "session wrapped".freeze
  # A session that narrated this recently may still be open in a terminal, so it
  # is "live", not something to chase.
  LIVE_FOR = 2.hours
  # Mailbox replies run headless in their own sessions; they never wrap, so they
  # are background and hidden by default.
  BACKGROUND_PATH = /agents-mailbox/
  DONE_STAGES = %w[shipped archived].freeze
  ENDINGS = %w[wrapped not_wrapped chase live].freeze
  # Claude Code keeps a session's transcript under ~/.claude/projects/<dir>/, where
  # <dir> is the session's working directory with "/" and "." turned into "-". The
  # decode holds only under ~/projects: a single "-" stays (repo names hold
  # dashes), and "--name-" is "/.name/" (a dot folder such as .worktrees, whose
  # name has no dash, then the desk inside it). Only plain
  # path characters match, so the copied command is safe to paste into a shell.
  PROJECT_DIR = %r{/\.claude/projects/-Users-(?<user>[A-Za-z0-9_]+)-projects(?<rest>[A-Za-z0-9._-]*)/}
  SAFE_SESSION_ID = /\A[A-Za-z0-9_-]+\z/

  Row = Struct.new(:session_id, :mascot_slug, :started_at, :last_at, :activity_count,
                   :wrapped, :background, :first_reason, :last_reason,
                   :task_count, :open_task_count, :first_task_slug, :last_task_slug,
                   :transcript_path, keyword_init: true) do
    def short_id = session_id.to_s.first(8)

    # The folder the session ran in, decoded from its transcript path, or nil
    # when the path is not a Claude Code transcript under ~/projects.
    def project_dir
      m = transcript_path.to_s.match(PROJECT_DIR) or return nil
      home = "/Users/#{m[:user]}/projects"
      rest = m[:rest]
      return home if rest.empty?
      return nil if rest.start_with?("--") || !rest.start_with?("-")

      dir = rest.delete_prefix("-")
                .gsub("--claude-worktrees-", "/.claude/worktrees/")
                .gsub(/--([A-Za-z0-9_]+)(-|\z)/) { "/.#{Regexp.last_match(1)}#{"/" if Regexp.last_match(2) == "-"}" }
      "#{home}/#{dir}"
    end

    # The terminal command that reopens the session: `claude --resume <id>`, run
    # from the folder the session ran in (resume finds a session only there).
    # Nil when the session is not a Claude Code one or the folder cannot be read.
    def resume_command
      dir = project_dir
      return nil unless dir && session_id.to_s.match?(SAFE_SESSION_ID)

      "cd #{dir} && claude --resume #{session_id}"
    end

    def live?(now = Time.current) = !wrapped && last_at && last_at > now - LIVE_FOR

    # The ending the page shows: wrapped, live, chase (not wrapped and still
    # holding open tasks) or not_wrapped.
    def ending(now = Time.current)
      return "wrapped" if wrapped
      return "live" if live?(now)
      return "chase" if open_task_count.positive?

      "not_wrapped"
    end
  end

  attr_reader :since, :now

  def initialize(now: Time.current, window: WINDOW)
    @now = now
    @since = now - window
  end

  # Every row, newest activity first. Background sessions are included; the
  # caller filters.
  def rows
    @rows ||= build_rows
  end

  def interactive_rows = rows.reject(&:background)

  # The rows one ending filter keeps ("all" or nil keeps every interactive row).
  # not_wrapped includes chase: both are sessions that never wrapped.
  def filtered(ending:, background: false)
    base = background ? rows : interactive_rows
    case ending.to_s
    when "wrapped" then base.select(&:wrapped)
    when "not_wrapped" then base.select { |r| %w[not_wrapped chase].include?(r.ending(now)) }
    when "chase" then base.select { |r| r.ending(now) == "chase" }
    when "live" then base.select { |r| r.ending(now) == "live" }
    else base
    end
  end

  def counts
    interactive = interactive_rows
    endings = interactive.map { |r| r.ending(now) }
    {
      sessions: interactive.size,
      wrapped: endings.count("wrapped"),
      not_wrapped: endings.count { |e| %w[not_wrapped chase].include?(e) },
      chase: endings.count("chase"),
      live: endings.count("live"),
      background: rows.size - interactive.size
    }
  end

  private

  def build_rows
    spans = activity_spans
    return [] if spans.empty?

    ids = spans.keys
    mascots = SessionMascot.where(session_id: ids).pluck(:session_id, :mascot_slug).to_h
    tasks = task_summaries(ids)
    reasons = reason_ends(ids)

    spans.map do |sid, s|
      t = tasks[sid] || {}
      Row.new(
        session_id: sid,
        mascot_slug: mascots[sid].presence || s[:mascot].presence,
        started_at: s[:started_at],
        last_at: s[:last_at],
        activity_count: s[:count],
        wrapped: s[:wrapped],
        background: s[:background],
        first_reason: reasons.dig(sid, :first),
        last_reason: reasons.dig(sid, :last),
        task_count: t[:total].to_i,
        open_task_count: t[:open].to_i,
        first_task_slug: t[:first_slug],
        last_task_slug: t[:last_slug],
        transcript_path: s[:path]
      )
    end.sort_by { |r| r.last_at || Time.at(0) }.reverse
  end

  # session_id => { started_at:, last_at:, count:, wrapped:, background:, mascot: }
  def activity_spans
    AgentActivity.where(opened_at: since..)
                 .group(:session_id)
                 .pluck(
                   :session_id,
                   Arel.sql("MIN(opened_at)"),
                   Arel.sql("MAX(COALESCE(closed_at, opened_at))"),
                   Arel.sql("COUNT(*)"),
                   # WRAP_OUTCOME is a constant, so wrapping the sanitized SQL is safe.
                   Arel.sql(AgentActivity.sanitize_sql_array(["BOOL_OR(LOWER(outcome_slug) = ?)", WRAP_OUTCOME])),
                   Arel.sql("MAX(transcript_path)"),
                   Arel.sql("MAX(mascot)")
                 ).to_h do |sid, started, last, count, wrapped, path, mascot|
      [sid, { started_at: started, last_at: last, count: count.to_i, wrapped: wrapped == true,
              background: path.to_s.match?(BACKGROUND_PATH), mascot: mascot, path: path }]
    end
  end

  # session_id => { first:, last: } — the reason of the session's first and latest
  # activity in the window. DISTINCT ON keeps one row per session in SQL, so the
  # page never loads the window's every activity row.
  def reason_ends(ids)
    out = Hash.new { |h, k| h[k] = {} }
    scope = AgentActivity.where(session_id: ids, opened_at: since..)
    scope.reorder(Arel.sql("session_id, opened_at ASC, seq ASC"))
         .pluck(Arel.sql("DISTINCT ON (session_id) session_id"), :reason_slug)
         .each { |sid, reason| out[sid][:first] = reason }
    scope.reorder(Arel.sql("session_id, opened_at DESC, seq DESC"))
         .pluck(Arel.sql("DISTINCT ON (session_id) session_id"), :reason_slug)
         .each { |sid, reason| out[sid][:last] = reason }
    out
  end

  # session_id => { total:, open:, first_slug:, last_slug: }
  def task_summaries(ids)
    out = {}
    Task.where(session_id: ids).order(:created_at).pluck(:session_id, :slug, :stage).each do |sid, slug, stage|
      row = (out[sid] ||= { total: 0, open: 0, first_slug: slug })
      row[:total] += 1
      row[:open] += 1 unless DONE_STAGES.include?(stage)
      row[:last_slug] = slug
    end
    out
  end
end
