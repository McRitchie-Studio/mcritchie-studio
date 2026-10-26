# frozen_string_literal: true

require "csv"
require "digest"
require "tmpdir"
require "json"
require "open3"
require "time"
require_relative "ci_failure_digest"

# ShipClock — prompt-to-production speed, measured from RECORDS (/tasks/ship-clock-benchmark).
#
# WHY. On 2026-10-13 Alex McRitchie timed an easy story (team-tier-nine-hundred) from his prompt
# to production. The agent could only ESTIMATE the start, because nothing stamped it,
# and every other number came from memory. bin/ship-clock stamps T0 at the prompt and
# rebuilds the rest of the timeline from what the pipeline already writes down:
#
#   the task row      created_at · started_at · submitted_at · reviewed_at ·
#                     assembled_at · completed_at (shipped) · archived_at
#   gate runs         GET /api/v1/gates/task/<slug> (dor refusals) and
#                     GET /api/v1/gates/release/<rel> (g3_candidate = QA, g4_ship = prod;
#                     its meta.release_events carries `assemble_release started`,
#                     the moment the release sweep began)
#   GitHub            `gh run list --branch` (every CI round), `gh pr view` (merge time),
#                     the failing jobs' logs for a red round's cause (CiFailureDigest)
#   ship logs         optional --log files: `bin/submit` pre-check refusals record
#                     nothing on the board, so the log is the only witness
#
# THE SPLIT. Every second between T0 and production lands in exactly one bucket:
#
#   rework    a red CI round, from its start to the next round's start (the fix rides
#             inside it); a failed QA or ship attempt, from its start to the retry's
#             start; a dor refusal, for its own run (its red CI round carries the rest)
#   wait      the final green CI round; the release sweep's pre-QA work, from the
#             sweep's start (assemble_release started) to the QA candidate's open
#             (merge-forward, gem publish, lock bumps: the pipeline working, not an
#             agent); the green QA candidate run; the green ship run
#   hands-on  everything else: the agent working, reviewing, and handing off
#
# Overlaps resolve by priority, rework over wait over hands-on, so a dor refusal inside
# a red CI round is not counted twice. Archive is reported but never counted: it runs
# after production and is not part of prompt-to-production.
#
# The pure parts (Phases, Timeline, Ledger) take plain data and are unit-tested in
# test/lib/ship_clock_test.rb; Sources is the thin I/O shell around the board and gh,
# driven end to end in test/lib/ship_clock_cli_test.rb.
module ShipClock
  # The board activity that carries a stamped T0 (metadata.kind).
  T0_KIND = "ship_clock_t0"
  DENVER = "America/Denver"
  RED_CONCLUSIONS = %w[failure timed_out startup_failure].freeze
  GREEN_CONCLUSIONS = %w[success].freeze
  BUCKETS = %i[hands_on wait rework].freeze
  # The release-grain gates: QA candidate (QA deploy + QA) and the production ship.
  RELEASE_GATES = %w[g3_candidate g4_ship].freeze
  PRIORITY = { rework: 2, wait: 1, hands_on: 0 }.freeze
  # A task slug as the board mints one (Task::DEPENDENCY_SLUG). The slug names a
  # file under ~/.ship-clock, so anything else (a `../x`) is refused, never joined.
  SLUG = /\A[a-z0-9]+(?:[-_][a-z0-9]+)*\z/
  # A full ISO 8601 timestamp: a date, a time, and a zone (Z or an offset). The
  # --at and --t0 flags take only this, so a bare `12` can never stamp a guessed day.
  STRICT_ISO = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})\z/
  # The most activity pages the T0 lookup walks (100 per page).
  T0_PAGE_LIMIT = 50

  # The default bound on every gh call, in seconds (SHIP_CLOCK_GH_TIMEOUT).
  GH_TIMEOUT_DEFAULT = 60.0

  class Error < StandardError; end

  module_function

  # SHIP_CLOCK_GH_TIMEOUT, read forgivingly: unset is the default; anything that
  # is not a positive number (`abc`, `0`, `-5`) is the default too, and yields the
  # bad value to the block so the caller can warn. A zero would kill gh at once.
  def gh_timeout(raw)
    return GH_TIMEOUT_DEFAULT if raw.nil? || raw.to_s.strip.empty?

    value = Float(raw.to_s.strip)
    raise ArgumentError unless value.positive? && value.finite?

    value
  rescue ArgumentError
    yield raw if block_given?
    GH_TIMEOUT_DEFAULT
  end

  def parse_time(value)
    return nil if value.nil? || value.to_s.strip.empty?
    return value.utc if value.is_a?(Time)

    Time.iso8601(value.to_s).utc
  rescue ArgumentError
    Time.parse(value.to_s).utc
  end

  def valid_slug?(slug) = slug.is_a?(String) && slug.match?(SLUG)

  # Operator input: a full ISO 8601 timestamp or nil. No Time.parse fallback here,
  # because that fallback reads `12` as the 12th of this month.
  def parse_strict(value)
    text = value.to_s.strip
    return nil unless text.match?(STRICT_ISO)

    Time.iso8601(text).utc
  rescue ArgumentError
    nil
  end

  # "08:25:14" in Denver time. TZ is swapped for the one conversion and put back.
  def denver(time, format = "%H:%M:%S")
    return "-" unless time

    prior = ENV.fetch("TZ", nil)
    ENV["TZ"] = DENVER
    time.getlocal.strftime(format)
  ensure
    ENV["TZ"] = prior
  end

  # 1263 → "21m03s"; 3789 → "1h03m09s".
  def duration(seconds)
    return "-" unless seconds

    s = seconds.round
    h, rem = s.divmod(3600)
    m, sec = rem.divmod(60)
    h.positive? ? format("%dh%02dm%02ds", h, m, sec) : format("%dm%02ds", m, sec)
  end

  # PURE. Classify [t0, finish] into the three buckets.
  # intervals: [{ bucket: :wait|:rework, from: Time, to: Time }]. Anything outside
  # [t0, finish] is clipped; an uncovered second is hands-on.
  module Phases
    module_function

    def split(t0:, finish:, intervals:)
      raise Error, "production time is before T0 (#{finish.iso8601} < #{t0.iso8601})" if finish < t0

      clipped = intervals.filter_map do |iv|
        from = [iv[:from], t0].max
        to = [iv[:to], finish].min
        next if to <= from

        { bucket: iv[:bucket].to_sym, from: from, to: to }
      end
      cuts = ([t0, finish] + clipped.flat_map { |iv| [iv[:from], iv[:to]] }).uniq.sort
      totals = BUCKETS.to_h { |b| [b, 0.0] }
      cuts.each_cons(2) do |a, b|
        covering = clipped.select { |iv| iv[:from] <= a && iv[:to] >= b }.map { |iv| iv[:bucket] }
        bucket = covering.max_by { |name| PRIORITY.fetch(name) } || :hands_on
        totals[bucket] += (b - a)
      end
      totals.transform_values(&:round).merge(total: (finish - t0).round)
    end
  end

  # PURE. Records in, report out. `records` is a Hash:
  #   task:          the board's task JSON
  #   task_gates:    gate runs for the task
  #   release_gates: gate runs for its release ([] when it has none yet)
  #   ci_runs:       `gh run list --json` rows for the branch
  #   pr:            `gh pr view --json createdAt,mergedAt` ({} when unknown)
  #   ci_causes:     { run_id => "cause line" } for the red runs
  #   t0:            { at: Time, source: "stamped"|"estimated"|... }
  #   log_lines:     lines from --log files ([] when none)
  module Timeline
    module_function

    def build(records)
      task = records.fetch(:task)
      t0 = records.fetch(:t0)
      rounds = ci_rounds(records.fetch(:ci_runs, []), records.fetch(:ci_causes, {}))
      task_gates = sort_gates(records.fetch(:task_gates, []))
      release_gates = sort_gates(records.fetch(:release_gates, []))
      prod_at, prod_source = production_time(task, release_gates)
      sweep_at, pre_qa = pre_qa_span(records.fetch(:release_events, []), release_gates)
      raise Error, "#{task["slug"]} has not reached production: no green g4_ship run and no shipped stamp" unless prod_at

      intervals = []
      rework = []
      rounds.each_with_index do |round, i|
        last = i == rounds.size - 1
        if round[:green] && last
          intervals << { bucket: :wait, from: round[:from], to: round[:to], label: "CI green #{round[:sha]}" }
        elsif !round[:green]
          to = last ? round[:to] : rounds[i + 1][:from]
          intervals << { bucket: :rework, from: round[:from], to: to }
          rework << { kind: round[:red] ? "red CI" : "CI #{round[:conclusion]}", from: round[:from], to: to,
                      seconds: (to - round[:from]).round, cause: round[:cause] }
        end
      end
      intervals << { bucket: :wait, from: pre_qa[:from], to: pre_qa[:to] } if pre_qa
      [task_gates, release_gates].each do |gates|
        gates.group_by { |g| g["key"] }.each_value do |runs|
          runs.each_with_index do |run, i|
            from = parse_time(run["started_at"])
            finished = parse_time(run["finished_at"]) || from
            next unless from

            if run["success"] == true
              intervals << { bucket: :wait, from: from, to: finished } if RELEASE_GATES.include?(run["key"])
            elsif run["success"] == false
              # A release gate's failure costs until its retry starts (the recovery
              # rides inside). A task gate's refusal is only its own instant: the red
              # CI round behind a dor refusal already carries that rework.
              nxt = runs[i + 1] && parse_time(runs[i + 1]["started_at"])
              to = RELEASE_GATES.include?(run["key"]) ? (nxt || finished) : finished
              intervals << { bucket: :rework, from: from, to: to }
              rework << { kind: "failed #{run["key"]} ##{run["attempt"]}", from: from, to: to,
                          seconds: (to - from).round, cause: gate_cause(run) }
            end
          end
        end
      end
      precheck = log_refusals(records.fetch(:log_lines, []))
      attach_log_causes(rework, records.fetch(:log_lines, []))

      split = Phases.split(t0: t0[:at], finish: prod_at, intervals: intervals)
      {
        "slug" => task["slug"],
        "title" => task["title"],
        "release_slug" => task["release_slug"],
        "t0" => t0[:at].iso8601,
        "t0_source" => t0[:source],
        "production_at" => prod_at.iso8601,
        "production_source" => prod_source,
        "archived_at" => parse_time(task["archived_at"])&.iso8601,
        "total_s" => split[:total],
        "hands_on_s" => split[:hands_on],
        "wait_s" => split[:wait],
        "rework_s" => split[:rework],
        "red_ci_rounds" => rounds.count { |r| r[:red] },
        "ci_rounds" => rounds.size,
        "refused_prechecks" => precheck.size,
        "failed_gates" => rework.count { |r| r[:kind].start_with?("failed ") },
        "rework" => (rework.sort_by { |r| r[:from] }.map { |r| stringify(r) } +
                     precheck.map { |line| { "kind" => "refused pre-check", "cause" => line } }),
        "pre_qa_wait_s" => pre_qa ? (pre_qa[:to] - pre_qa[:from]).round : 0,
        "milestones" => milestones(task, t0, rounds, records.fetch(:pr, {}), task_gates, release_gates, prod_at,
                                   sweep_at)
      }
    end

    def parse_time(value) = ShipClock.parse_time(value)

    # The release sweep's pre-QA span: from the first `assemble_release started`
    # event (Release::Conductor.sweep!) to the first QA candidate's open. Returns
    # [sweep_start, { from:, to: }] or [sweep_start_or_nil, nil] when either end
    # is missing or out of order (a board that predates the events read, or a
    # release that never reached QA): that span then stays hands-on, as before.
    def pre_qa_span(events, release_gates)
      sweep_at = Array(events).select { |e| e["step"] == "assemble_release" && e["status"] == "started" }
                              .filter_map { |e| parse_time(e["occurred_at"]) }.min
      qa_open = release_gates.select { |g| g["key"] == "g3_candidate" }
                             .filter_map { |g| parse_time(g["started_at"]) }.min
      return [sweep_at, nil] unless sweep_at && qa_open && sweep_at < qa_open

      [sweep_at, { from: sweep_at, to: qa_open }]
    end

    def stringify(row)
      row.to_h { |k, v| [k.to_s, v.is_a?(Time) ? v.iso8601 : v] }
    end

    def sort_gates(gates)
      Array(gates).sort_by { |g| [g["key"].to_s, g["attempt"].to_i, g["started_at"].to_s] }
    end

    # One round per pushed SHA, in push order. A round is green when every run on it
    # passed, red when any run failed.
    def ci_rounds(runs, causes)
      Array(runs).group_by { |r| r["headSha"] }.map do |sha, group|
        conclusions = group.map { |r| r["conclusion"].to_s }
        red_runs = group.select { |r| RED_CONCLUSIONS.include?(r["conclusion"].to_s) }
        {
          sha: sha.to_s[0, 7],
          from: group.map { |r| parse_time(r["startedAt"] || r["createdAt"]) }.compact.min,
          to: group.map { |r| parse_time(r["updatedAt"]) }.compact.max,
          green: conclusions.all? { |c| GREEN_CONCLUSIONS.include?(c) },
          red: red_runs.any?,
          conclusion: (conclusions - GREEN_CONCLUSIONS).first || "success",
          cause: red_runs.filter_map { |r| causes[r["databaseId"]] || causes[r["databaseId"].to_s] }.first
        }
      end.reject { |r| r[:from].nil? || r[:to].nil? }.sort_by { |r| r[:from] }
    end

    # The green g4_ship's finish is the moment production answered; the task's
    # shipped stamp (completed_at) is the fallback for a release that predates gates.
    def production_time(task, release_gates)
      green = release_gates.select { |g| g["key"] == "g4_ship" && g["success"] == true }.last
      at = green && parse_time(green["finished_at"])
      return [at, "g4_ship"] if at

      shipped = parse_time(task["completed_at"]) if %w[shipped archived].include?(task["stage"].to_s)
      shipped ? [shipped, "task completed_at"] : [nil, nil]
    end

    # The cause a gate run recorded, when it recorded one.
    def gate_cause(run)
      sops = Array(run["sops"])
      failed = sops.select { |s| s["result"].to_s == "fail" }
      named = failed.map { |s| s["cause"] || s["reason"] }.compact.first
      return named.to_s[0, 200] if named
      return "#{failed.map { |s| s["sop"] }.uniq.join(", ")} failed" if failed.any?
      return "aborted (no cause recorded on the gate run)" if run.dig("metadata", "aborted")

      nil
    end

    # A failed QA or ship run that recorded no cause borrows one from the --log files:
    # each distinct "✗ …" line, in order, goes to the next such run. The ship and
    # release scripts print their refusal on a ✗ line; the gate run keeps only `aborted`.
    def attach_log_causes(rework, lines)
      causes = Array(lines).map(&:strip).select { |l| l.start_with?("✗") }.uniq
      rework.each do |row|
        next unless row[:kind].start_with?("failed g") && (row[:cause].nil? || row[:cause].start_with?("aborted"))
        break if causes.empty?

        row[:cause] = "#{causes.shift.delete_prefix("✗").split(" — ").first.strip[0, 160]} (from --log)"
      end
    end

    # `bin/submit` prints this when its 0/8 pre-check refuses; the board records nothing.
    PRECHECK_REFUSAL = /the DoR pre-check refused/
    def log_refusals(lines)
      Array(lines).each_with_index.filter_map do |line, i|
        next unless line.match?(PRECHECK_REFUSAL)

        cause = Array(lines)[0...i].reverse.find { |l| l.strip.start_with?("✗", "REFUSED", "refused") }
        (cause || line).strip[0, 200]
      end
    end

    def milestones(task, t0, rounds, pr, task_gates, release_gates, prod_at, sweep_at = nil)
      rows = [["T0 (#{t0[:source]})", t0[:at]]]
      rows << ["release sweep started", sweep_at]
      rows << ["task created (desk cut)", parse_time(task["created_at"])]
      rows << ["building", parse_time(task["started_at"])]
      rows << ["PR opened", parse_time(pr["createdAt"])]
      rounds.each_with_index do |r, i|
        rows << ["CI round #{i + 1} #{r[:sha]} #{r[:green] ? "green" : r[:conclusion]}", r[:to]]
      end
      task_gates.each do |g|
        rows << ["#{g["key"]} ##{g["attempt"]} #{g["success"] ? "pass" : "fail"}", parse_time(g["finished_at"])]
      end
      rows << ["submitted", parse_time(task["submitted_at"])]
      rows << ["merged", parse_time(pr["mergedAt"])]
      rows << ["reviewed", parse_time(task["reviewed_at"])]
      release_gates.each do |g|
        label = { "g3_candidate" => "QA candidate", "g4_ship" => "production ship" }.fetch(g["key"], g["key"])
        rows << ["#{label} ##{g["attempt"]} start", parse_time(g["started_at"])]
        rows << ["#{label} ##{g["attempt"]} #{g["success"] ? "green" : "failed"}", parse_time(g["finished_at"])]
      end
      rows << ["assembled", parse_time(task["assembled_at"])]
      rows << ["shipped", parse_time(task["completed_at"])]
      rows << ["archived (not counted)", parse_time(task["archived_at"])]
      rows.select { |_, at| at }.sort_by { |_, at| at }.map do |label, at|
        { "label" => label, "at" => at.iso8601, "elapsed_s" => (at - t0[:at]).round,
          "counted" => at <= prod_at }
      end
    end
  end

  # PURE-ish. The version-controlled ledger: one row per benchmark run, keyed by slug.
  module Ledger
    HEADER = %w[date slug t0 t0_source production_at total_min hands_on_min wait_min rework_min
                red_ci_rounds notes].freeze

    module_function

    def minutes(seconds) = format("%.1f", seconds.to_f / 60)

    def row(report, note: nil)
      notes = auto_notes(report)
      notes << note.to_s.strip unless note.to_s.strip.empty?
      [
        ShipClock.denver(ShipClock.parse_time(report["t0"]), "%Y-%m-%d"),
        report["slug"], report["t0"], report["t0_source"], report["production_at"],
        minutes(report["total_s"]), minutes(report["hands_on_s"]), minutes(report["wait_s"]),
        minutes(report["rework_s"]), report["red_ci_rounds"].to_i, notes.join("; ")
      ]
    end

    def auto_notes(report)
      Array(report["rework"]).map do |r|
        [r["kind"], r["seconds"] && ShipClock.duration(r["seconds"]), r["cause"]].compact.join(" ")
      end
    end

    # The lock lives in the temp dir, keyed by the ledger's REAL path, so it never
    # lands in the tree as a stray file beside the version-controlled ledger, and
    # two spellings of one file (a symlinked tree, a relative path) share one lock.
    # A ledger not yet written resolves through its directory.
    def lock_path(path)
      File.join(Dir.tmpdir, "ship-clock-#{Digest::SHA256.hexdigest(real_path(path))[0, 16]}.lock")
    end

    def real_path(path)
      File.realpath(path)
    rescue Errno::ENOENT
      dir = File.dirname(File.expand_path(path))
      File.join(File.directory?(dir) ? File.realpath(dir) : dir, File.basename(path))
    end

    # Append the run's row, or REPLACE the slug's earlier row (a re-run after a fix
    # must not leave two answers for one run). Returns :appended or :replaced.
    # Two writers cannot interleave: the read-modify-write runs under an exclusive
    # lock (lock_path), and the new ledger lands by temp file plus rename, so
    # a reader never sees half a file.
    def write!(path, row)
      File.open(lock_path(path), File::RDWR | File::CREAT, 0o644) do |lock|
        lock.flock(File::LOCK_EX)
        rows = File.exist?(path) ? CSV.read(path) : []
        rows = [HEADER] if rows.empty?
        raise Error, "#{path} does not start with the ship-clock header" unless rows.first == HEADER

        index = rows.index { |r| r[1] == row[1] }
        outcome = index ? :replaced : :appended
        index ? rows[index] = row : rows << row
        tmp = "#{path}.tmp-#{Process.pid}"
        begin
          # fsync before the rename: a crash after it must never leave a ledger
          # that names a row the disk never held.
          File.open(tmp, "w") do |f|
            f.write(rows.map { |r| CSV.generate_line(r) }.join)
            f.flush
            f.fsync
          end
          File.rename(tmp, path)
        ensure
          File.delete(tmp) if File.exist?(tmp)
        end
        outcome
      end
    end
  end

  # The I/O shell: the board over HTTP (TaskBoard) and gh through a runner.
  class Sources
    attr_reader :repo_of

    # board: ->(path) { parsed JSON Hash } ; gh: ->(args) { [stdout, ok] }
    def initialize(board:, gh:)
      @board = board
      @gh = gh
    end

    def task(slug) = data(@board.call("/api/v1/tasks/#{slug}"))

    def gates(type, slug) = Array(data(@board.call("/api/v1/gates/#{type}/#{slug}")))

    # A release's gate runs AND its stage events (meta.release_events), in one read.
    def release_gates(slug)
      payload = @board.call("/api/v1/gates/release/#{slug}")
      events = payload.is_a?(Hash) ? Array(payload.dig("meta", "release_events")) : []
      [Array(data(payload)), events]
    end

    # The newest T0 note, from EVERY page of the task's comments: a busy task can
    # carry more than 100, and the T0 is the oldest of them.
    def t0_note(slug)
      rows = []
      (1..T0_PAGE_LIMIT).each do |page|
        payload = @board.call("/api/v1/activities?task_slug=#{slug}&activity_type=comment&per_page=100&page=#{page}")
        batch = Array(data(payload))
        rows.concat(batch)
        total_pages = payload.is_a?(Hash) ? payload.dig("meta", "total_pages").to_i : 0
        break if batch.empty? || page >= total_pages
      end
      rows.select { |a| a.dig("metadata", "kind") == T0_KIND }.max_by { |a| a["created_at"].to_s }
    end

    def ci_runs(repo, branch)
      gh_json(["run", "list", "--repo", repo, "--branch", branch, "--limit", "100", "--json",
               "databaseId,headSha,conclusion,status,createdAt,startedAt,updatedAt,workflowName,event"]) ||
        raise(Error, "gh run list failed for #{branch}; refresh gh auth and re-run (a missing CI read would misfile CI time as hands-on)")
    end

    def pr(url)
      gh_json(["pr", "view", url, "--json", "createdAt,mergedAt"]) ||
        raise(Error, "gh pr view failed for #{url}; refresh gh auth and re-run")
    end

    # The first failing test (or failing job) of a red run, read from its jobs' logs.
    def ci_cause(repo, run_id)
      view = gh_json(["run", "view", run_id.to_s, "--repo", repo, "--json", "jobs"]) || {}
      failed = Array(view["jobs"]).select { |j| RED_CONCLUSIONS.include?(j["conclusion"].to_s) }
      real = failed.reject { |j| j["name"].to_s.match?(CiFailureDigest::ECHO_JOB) }
      failed = real unless real.empty?
      failed.each do |job|
        log, ok = @gh.call(["api", "repos/#{repo}/actions/jobs/#{job["databaseId"]}/logs"])
        next unless ok

        found = CiFailureDigest.extract(log)
        first = found[:failures].first
        return "#{job["name"]}: #{first[:location] || first[:name]}" if first
        return "#{job["name"]}: #{found[:infra]}" if found[:infra]
      end
      failed.first && "#{failed.first["name"]} failed"
    rescue StandardError
      nil
    end

    private

    def data(payload)
      payload.is_a?(Hash) && payload.key?("data") ? payload["data"] : payload
    end

    def gh_json(args)
      out, ok = @gh.call(args)
      return nil unless ok

      JSON.parse(out)
    rescue JSON::ParserError
      nil
    end
  end

  # "https://github.com/O/R/pull/12" → "O/R".
  def repo_from_pr(url)
    m = url.to_s.match(%r{github\.com/([^/]+/[^/]+)/pull/\d+})
    m && m[1]
  end

  # Gather every record for `slug` and build the report. t0_override: { at:, source: }.
  def report(slug, sources:, t0_override: nil, pending: nil, log_lines: [])
    task = sources.task(slug)
    raise Error, "no task #{slug} on the board" unless task.is_a?(Hash) && task["slug"]

    t0 = t0_override || stamped_t0(sources.t0_note(slug)) || pending ||
         { at: parse_time(task["created_at"]), source: "task created_at (no T0 stamped)" }
    pr_url = task["pr_url_or_derived"] || task["pr_url"]
    repo = repo_from_pr(pr_url)
    runs = repo && task["branch"] ? sources.ci_runs(repo, task["branch"]) : []
    causes = runs.select { |r| RED_CONCLUSIONS.include?(r["conclusion"].to_s) }
                 .to_h { |r| [r["databaseId"], sources.ci_cause(repo, r["databaseId"])] }
    release_gates, release_events = task["release_slug"] ? sources.release_gates(task["release_slug"]) : [[], []]
    Timeline.build(
      task: task, t0: t0, ci_runs: runs, ci_causes: causes,
      pr: pr_url ? sources.pr(pr_url) : {},
      task_gates: sources.gates("task", slug),
      release_gates: release_gates, release_events: release_events,
      log_lines: log_lines
    )
  end

  def stamped_t0(note)
    return nil unless note

    at = parse_time(note.dig("metadata", "t0") || note["created_at"])
    at && { at: at, source: note.dig("metadata", "estimated") ? "estimated" : "stamped" }
  end

  # The human report: the stage table, then the three-way split, then the rework.
  def render(report)
    out = []
    out << "ship-clock · #{report["slug"]} · #{report["title"]}"
    out << "T0 #{denver(parse_time(report["t0"]))} MDT (#{report["t0_source"]}) → production " \
           "#{denver(parse_time(report["production_at"]))} MDT (#{report["production_source"]})"
    out << ""
    out << format("  %-8s  %-9s  %s", "Denver", "elapsed", "stage")
    report["milestones"].each do |m|
      out << format("  %-8s  %-9s  %s%s", denver(parse_time(m["at"])), duration(m["elapsed_s"]), m["label"],
                    m["counted"] ? "" : "  (after production, not counted)")
    end
    out << ""
    total = report["total_s"].to_f
    pct = ->(s) { total.positive? ? format("%3d%%", (s * 100 / total).round) : "  -" }
    out << "  total     #{duration(report["total_s"])}"
    out << "  hands-on  #{duration(report["hands_on_s"])}  #{pct.call(report["hands_on_s"])}"
    out << "  wait      #{duration(report["wait_s"])}  #{pct.call(report["wait_s"])}  (CI, the sweep's pre-QA work, QA deploy, production deploy)"
    out << "  rework    #{duration(report["rework_s"])}  #{pct.call(report["rework_s"])}  " \
           "(#{report["red_ci_rounds"]} red CI round(s), #{report["failed_gates"]} failed gate run(s), " \
           "#{report["refused_prechecks"]} refused pre-check(s) from logs)"
    Array(report["rework"]).each do |r|
      out << "    · #{r["kind"]}#{r["seconds"] ? " #{duration(r["seconds"])}" : ""}#{r["cause"] ? " — #{r["cause"]}" : ""}"
    end
    out.join("\n")
  end
end
