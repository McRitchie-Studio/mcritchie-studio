# frozen_string_literal: true

module Insights
  # Grades a SHIPPED task once, from facts already on the board, and writes AT MOST
  # ONE learning line — the learning loop baked into the devops flow (devops-v3
  # piece 6; docs/agents/system/devops-v3-design.md §9). No LLM call: every fact is
  # a query, every threshold is a number in config/learning_loop.yml, and the
  # learning is a deterministic template naming the threshold and its evidence.
  #
  # THE FACTS
  #   size          po_size / dev_size / actual_size, and how far actual landed from po
  #   bounces       qa_feedback rows BounceLedger counts (kind rework, or no kind)
  #   gate_failures GateRun success=false per task-grain gate key
  #   build/review  first `→ building` to last `→ submitted`; last `→ submitted` to `→ shipped`
  #   cost/tokens   summed across the task's TaskEvents (Task#total_cost)
  #   lines         additions + deletions on the PR, best-effort (nil when unreadable)
  #   escalation    an `Escalated:` block, or an arbitrate-block `RULING:` note
  #
  # THE THRESHOLDS trip on: bounces >= N, any gate failing >= N times, an escalation,
  # or cost / build / review time above the trailing percentile of recently shipped
  # tasks. A percentile with too thin a sample (min_samples) is skipped, not tripped.
  #
  # THE CAP. Nothing tripped → verdict "nothing to learn", and nothing else is
  # written. Something tripped → ONE line, claimed by the highest-priority threshold
  # (config `priority`); the rest are recorded on the grade's `tripped` list and
  # named in the line's tail, never as extra learnings. The line lands as a task note
  # (comment, metadata kind "learning") and as a banked ActionGrade, which is what
  # GET /api/v1/insights (and so bin/session-insights) serves.
  #
  #   Insights::TaskGrader.grade!("some-task")                 # write (the ship hook)
  #   Insights::TaskGrader.new(task, baseline: b).assessment   # read-only (the backfill)
  class TaskGrader
    CONFIG_PATH = Rails.root.join("config/learning_loop.yml")
    GRADER = ActionGrade::XAN
    # BounceLedger's rule (bin/lib/bounce_ledger.rb): every qa_feedback row counts
    # EXCEPT these kinds — an unknown or missing kind counts, as it does there.
    NON_BOUNCE_KINDS = %w[environment dependency].freeze
    ESCALATION_PREFIX = Devops::Windows::ESCALATION_PREFIX
    RULING_PREFIX = "RULING:"
    EVIDENCE_LIMIT = 160

    Assessment = Struct.new(:facts, :tripped, :learning, :headline, keyword_init: true) do
      def verdict
        learning ? TaskGrade::LEARNING : TaskGrade::NOTHING_TO_LEARN
      end
    end

    # Every task that SHIPPED: `shipped`, plus `archived` rows that carry a ship stamp
    # (completed_at is written only on the move into `shipped`), because
    # archive-shipped sweeps shipped tasks into `archived` — on 2026-09-25 one of the
    # last 100 shipped tasks still read `shipped`. A window of `stage: "shipped"` alone
    # would measure almost nothing.
    def self.shipped_tasks
      Task.where(stage: %w[shipped archived]).where.not(completed_at: nil)
    end

    def self.config(path = CONFIG_PATH)
      @config ||= {}
      @config[path.to_s] ||= (YAML.safe_load_file(path) || {})
    end

    def self.reload!
      @config = nil
    end

    # Grade one task by slug and persist the result. Returns the TaskGrade, or nil
    # when the task never shipped. Idempotent: an existing grade is returned as-is.
    def self.grade!(task_slug, baseline: nil, pr_reader: nil)
      task = shipped_tasks.find_by(slug: task_slug)
      return nil unless task

      existing = TaskGrade.find_by(task_slug: task.slug)
      return existing if existing

      new(task, baseline: baseline, pr_reader: pr_reader).grade!
    end

    def initialize(task, baseline: nil, pr_reader: nil, config: self.class.config)
      @task = task
      @config = config
      @baseline = baseline || Baseline.build(exclude: task.slug, config: config)
      @pr_reader = pr_reader || PrLines.new
    end

    # Read-only: the facts, the tripped thresholds, and the learning line (or nil).
    def assessment
      @assessment ||= begin
        facts = gather_facts
        tripped = trip(facts)
        headline, learning = compose(tripped)
        Assessment.new(facts: facts, tripped: tripped, learning: learning, headline: headline)
      end
    end

    # Persist the grade — and, when a threshold tripped, the ONE learning note and its
    # banked ActionGrade — in one transaction. A racing writer loses on the unique
    # task_slug index and gets the winner's row back.
    def grade!
      result = assessment
      TaskGrade.transaction do
        grade = TaskGrade.create!(
          task_slug: @task.slug, grader: GRADER, verdict: result.verdict,
          facts: result.facts, tripped: result.tripped.map { |t| t[:key] },
          learning: result.learning, graded_at: Time.current
        )
        record_learning!(grade, result) if result.learning
        grade
      end
    rescue ActiveRecord::RecordNotUnique
      TaskGrade.find_by(task_slug: @task.slug)
    end

    private

    # --- facts ------------------------------------------------------------------

    def gather_facts
      transitions = @task.task_events.transitions.chronological.to_a
      {
        "po_size" => @task.po_size,
        "dev_size" => @task.dev_size,
        "actual_size" => @task.actual_size,
        "size_delta" => size_delta(@task.po_size, @task.actual_size),
        "bounces" => bounce_rows.size,
        "bounce_summaries" => bounce_rows.map { |a| summary_of(a) }.first(3),
        "gate_failures" => gate_failures,
        "build_seconds" => Baseline.build_seconds(transitions),
        "review_seconds" => Baseline.review_seconds(transitions),
        "cost" => @task.total_cost.to_f.round(4),
        "tokens" => @task.measured_tokens_total.to_i,
        "lines_changed" => @pr_reader.lines_for(@task.devops_url("pr")),
        "escalation" => escalation_evidence,
        "baseline" => @baseline.to_h
      }
    end

    def size_delta(forecast, actual)
      a = Task::SIZES.index(forecast.to_s)
      b = Task::SIZES.index(actual.to_s)
      a && b ? b - a : nil
    end

    def activities
      @activities ||= Activity.where(task_slug: @task.slug).conversation_order.to_a
    end

    # BounceLedger's countable rows: a qa_feedback send-back of kind rework, or one
    # that carries no kind. An environment or dependency block (the escalation
    # itself included) is not a bounce.
    def bounce_rows
      @bounce_rows ||= activities.select do |a|
        a.activity_type == "qa_feedback" &&
          NON_BOUNCE_KINDS.exclude?(a.metadata.to_h["kind"].to_s.strip) &&
          !escalation_row?(a)
      end
    end

    def gate_failures
      GateRun.where(subject_type: "task", subject_slug: @task.slug, success: false)
             .group(:key).count.sort.to_h
    end

    def escalation_row?(activity)
      activity.activity_type == "qa_feedback" && summary_of(activity).start_with?(ESCALATION_PREFIX)
    end

    # The RULING line wins as evidence (it is the settled answer); an Escalated:
    # block alone still trips. nil when neither is on the task.
    def escalation_evidence
      ruling = activities.reverse.find { |a| a.description.to_s.lstrip.start_with?(RULING_PREFIX) }
      return first_line(ruling.description) if ruling

      escalated = activities.reverse.find { |a| escalation_row?(a) }
      escalated && summary_of(escalated)
    end

    def summary_of(activity)
      activity.metadata.to_h["summary"].to_s.strip.presence || first_line(activity.description)
    end

    def first_line(text)
      text.to_s.strip.lines.first.to_s.strip.truncate(EVIDENCE_LIMIT)
    end

    # --- thresholds ---------------------------------------------------------------

    def trip(facts)
      tripped = []
      if facts["escalation"]
        tripped << { key: "escalation", headline: "escalated to the operator",
                     evidence: facts["escalation"] }
      end
      if facts["bounces"] >= @config.fetch("bounces", 2).to_i
        tripped << { key: "bounces", headline: "bounced #{facts["bounces"]} times",
                     evidence: facts["bounce_summaries"].join("; ") }
      end
      failing = facts["gate_failures"].select { |_k, n| n >= @config.fetch("gate_failures", 3).to_i }
      if failing.any?
        tripped << { key: "gate_failures", headline: "gate #{failing.keys.join(", ")} failed repeatedly",
                     evidence: failing.map { |k, n| "#{k} failed #{n}x" }.join(", ") }
      end
      trip_percentile(tripped, "cost", facts["cost"]) { |v, p| ["cost above p#{pct}", "$#{format("%.2f", v)} vs p#{pct} $#{format("%.2f", p)}"] }
      trip_percentile(tripped, "build_cycle", facts["build_seconds"]) { |v, p| ["slow build", "#{hours(v)} building vs p#{pct} #{hours(p)}"] }
      trip_percentile(tripped, "review_cycle", facts["review_seconds"]) { |v, p| ["slow review to ship", "#{hours(v)} submitted-to-shipped vs p#{pct} #{hours(p)}"] }
      order = Array(@config["priority"])
      tripped.sort_by { |t| order.index(t[:key]) || order.size }
    end

    def trip_percentile(tripped, key, value)
      ceiling = @baseline.percentile(key)
      return if value.nil? || ceiling.nil? || value.to_f <= ceiling

      headline, evidence = yield(value.to_f, ceiling)
      tripped << { key: key, headline: headline, evidence: evidence }
    end

    def pct
      @config.fetch("percentile", 90).to_i
    end

    def hours(seconds)
      format("%.1fh", seconds.to_f / 3600)
    end

    # --- the one line ---------------------------------------------------------------

    # [headline, line] for the top tripped threshold, or [nil, nil]. The headline is
    # the ActionGrade slug (short, like the other grades); the line is the full
    # learning with its evidence and any other thresholds that tripped.
    def compose(tripped)
      return [nil, nil] if tripped.empty?

      top = tripped.first
      line = "#{@task.slug}: #{top[:headline]}"
      line += " — #{top[:evidence]}" if top[:evidence].present?
      others = tripped.drop(1).map { |t| t[:key] }
      line += " (also tripped: #{others.join(", ")})" if others.any?
      [top[:headline], line]
    end

    def record_learning!(grade, result)
      note = Activity.create!(
        task_slug: @task.slug, activity_type: "comment", agent_slug: GRADER,
        description: "Learning: #{result.learning}",
        metadata: { "kind" => "learning", "tripped" => grade.tripped }
      )
      banked = bank!(note, result)
      facts = banked ? grade.facts : grade.facts.merge("feed" => "no narrated activity to bank against")
      grade.update!(note_activity_slug: note.slug, action_grade_id: banked&.id, facts: facts)
    end

    # The insight feed reads ActionGrade.banked, and an ActionGrade must hang off an
    # action or an activity (its XOR). Like Insights::BlockMiner, hang it off the
    # task's newest narrated activity Xan has not graded yet, builder lane first.
    # No activity → the learning stays on the task note and the grade, and the feed
    # does not carry it (recorded in facts so the gap is visible, not silent).
    def bank!(note, result)
      activity = feed_anchor
      return nil unless activity

      ActionGrade.create!(
        grader: GRADER, disposition: ActionGrade::NOT, agent_activity: activity,
        slug: result.headline, long_form: result.learning, source_activity_slug: note.slug,
        banked: true
      )
    end

    def feed_anchor
      graded = ActionGrade.by_grader(GRADER).where.not(agent_activity_id: nil).select(:agent_activity_id)
      scope = AgentActivity.where(task_slug: @task.slug).where.not(id: graded)
                           .order(opened_at: :desc, id: :desc)
      scope.where(agent: [nil, ""]).first || scope.first
    end

    # The trailing window of shipped tasks the percentile thresholds measure against.
    # Built once per backfill (and once per job) with three grouped queries, never per
    # task. Percentiles take only NON-ZERO values and refuse to answer below
    # min_samples, so a window of unpriced tasks cannot make every priced one an outlier.
    class Baseline
      KEYS = %w[cost build_cycle review_cycle].freeze

      def self.build(exclude: nil, config: TaskGrader.config, before: nil)
        window = config.fetch("trailing_window", 100).to_i
        scope = TaskGrader.shipped_tasks
        scope = scope.where.not(slug: exclude) if exclude
        scope = scope.where(completed_at: ...before) if before
        slugs = scope.order(completed_at: :desc).limit(window).pluck(:slug)
        new(samples_for(slugs), config: config)
      end

      def self.samples_for(slugs)
        return KEYS.index_with { [] } if slugs.empty?

        costs = TaskEvent.where(task_slug: slugs).group(:task_slug).sum(:cost)
        rows = TaskEvent.transitions.where(task_slug: slugs, to_stage: %w[building submitted shipped])
                        .order(:occurred_at, :id).pluck(:task_slug, :to_stage, :occurred_at)
        by_task = rows.group_by(&:first).transform_values { |r| r.map { |_s, stage, at| Stamp.new(stage, at) } }
        {
          "cost" => slugs.map { |s| costs[s].to_f },
          "build_cycle" => slugs.map { |s| build_seconds(by_task[s]) },
          "review_cycle" => slugs.map { |s| review_seconds(by_task[s]) }
        }
      end

      Stamp = Struct.new(:to_stage, :occurred_at)

      # First `→ building` to the last `→ submitted` after it: the whole build,
      # bounces included.
      def self.build_seconds(transitions)
        list = Array(transitions)
        start = list.find { |t| t.to_stage == "building" }&.occurred_at
        finish = list.reverse.find { |t| t.to_stage == "submitted" }&.occurred_at
        start && finish && finish > start ? (finish - start).round : nil
      end

      # Last `→ submitted` to `→ shipped`: review, release, and ship.
      def self.review_seconds(transitions)
        list = Array(transitions)
        shipped = list.reverse.find { |t| t.to_stage == "shipped" }&.occurred_at
        submitted = list.reverse.find { |t| t.to_stage == "submitted" && (shipped.nil? || t.occurred_at <= shipped) }&.occurred_at
        submitted && shipped && shipped > submitted ? (shipped - submitted).round : nil
      end

      def initialize(samples, config: TaskGrader.config)
        @samples = samples
        @percentile = config.fetch("percentile", 90).to_f
        @min_samples = config.fetch("min_samples", 20).to_i
      end

      # The configured percentile of the non-zero sample for a key, or nil when the
      # sample is thinner than min_samples.
      def percentile(key, pct = @percentile)
        values = nonzero(key)
        return nil if values.size < @min_samples

        rank = ((pct / 100.0) * values.size).ceil.clamp(1, values.size)
        values[rank - 1]
      end

      def median(key)
        percentile(key, 50)
      end

      def to_h
        KEYS.to_h do |key|
          [key, { "n" => nonzero(key).size, "p50" => median(key), "p#{@percentile.to_i}" => percentile(key) }]
        end
      end

      private

      def nonzero(key)
        @nonzero ||= {}
        @nonzero[key] ||= Array(@samples[key]).compact.map(&:to_f).select(&:positive?).sort
      end
    end

    # The dry-run (default) and live backfill over the most recently shipped tasks —
    # what `bin/rails learning_loop:backfill` runs, so Alex can read the loop's output
    # before it grades anything for real. Dry run writes NOTHING; live grades each
    # ungraded task exactly as the ship hook would (idempotent — graded ones are
    # skipped). One Baseline serves the whole run: the current trailing window.
    class Backfill
      COLUMNS = [["task", 34], ["po>act", 8], ["bnc", 3], ["gate fails", 12], ["build", 6],
                 ["review", 6], ["cost", 8], ["lines", 6], ["verdict", 0]].freeze

      def self.run(limit: 30, live: false, io: $stdout, pr_reader: nil)
        new(limit: limit, live: live, io: io, pr_reader: pr_reader).run
      end

      def initialize(limit:, live:, io:, pr_reader:)
        @limit = limit.to_i.clamp(1, 500)
        @live = live
        @io = io
        @pr_reader = pr_reader || PrLines.new
      end

      # Returns the per-task rows ({slug:, assessment:, graded:}) it printed.
      def run
        baseline = Baseline.build
        tasks = TaskGrader.shipped_tasks.order(completed_at: :desc).limit(@limit).to_a
        @io.puts "learning_loop:backfill — #{@live ? "LIVE" : "DRY RUN (nothing written)"} · " \
                 "last #{tasks.size} shipped · baseline #{baseline_label(baseline)}"
        @io.puts header
        rows = tasks.map { |task| row_for(task, baseline) }
        learnings = rows.count { |r| r[:assessment].learning }
        @io.puts "#{learnings} of #{rows.size} would write a learning; #{rows.size - learnings} nothing to learn."
        rows
      end

      private

      def row_for(task, baseline)
        grader = TaskGrader.new(task, baseline: baseline, pr_reader: @pr_reader)
        result = grader.assessment
        graded = @live && !TaskGrade.exists?(task_slug: task.slug) ? grader.grade! : nil
        @io.puts line(task, result)
        { slug: task.slug, assessment: result, graded: graded }
      end

      def line(task, result)
        f = result.facts
        cells = [
          task.slug, "#{f["po_size"] || "-"}>#{f["actual_size"] || "-"}", f["bounces"].to_s,
          f["gate_failures"].map { |k, n| "#{k}:#{n}" }.join(",").presence || "-",
          hours(f["build_seconds"]), hours(f["review_seconds"]), format("$%.2f", f["cost"]),
          f["lines_changed"]&.to_s || "?", result.learning ? "LEARN #{result.learning}" : "nothing to learn"
        ]
        COLUMNS.each_with_index.map { |(_, w), i| w.zero? ? cells[i] : cells[i].to_s.truncate(w).ljust(w) }.join(" ")
      end

      def header
        COLUMNS.map { |name, w| w.zero? ? name : name.ljust(w) }.join(" ")
      end

      def hours(seconds)
        seconds ? format("%.1fh", seconds.to_f / 3600) : "-"
      end

      def baseline_label(baseline)
        baseline.to_h.map do |key, stats|
          ceiling = stats.values.last
          shown = if ceiling.nil? then "skip"
                  elsif key == "cost" then format("$%.2f", ceiling)
                  else hours(ceiling)
                  end
          "#{key} n=#{stats["n"]} #{stats.keys.last}=#{shown}"
        end.join(", ")
      end
    end

    # Lines changed on the task's PR — additions + deletions from GitHub. Best-effort
    # by contract: any failure (no URL, no token, 404, rate limit) reads nil, never 0,
    # and never raises into the grade.
    class PrLines
      PR_PATTERN = %r{github\.com/([^/]+/[^/]+)/pull/(\d+)}

      def initialize(client: nil)
        @client = client
      end

      def lines_for(pr_url)
        repo, number = pr_url.to_s.match(PR_PATTERN)&.captures
        return nil unless repo && number

        pr = client.get("/repos/#{repo}/pulls/#{number}")
        return nil unless pr.is_a?(Hash)

        additions = pr["additions"]
        deletions = pr["deletions"]
        additions && deletions ? additions.to_i + deletions.to_i : nil
      rescue StandardError => e
        Rails.logger.info("[task-grader] PR lines unreadable for #{pr_url}: #{e.class}")
        nil
      end

      private

      def client
        # No retries and no rate-limit sleep: a grade must never wait a minute on
        # GitHub for a fact it is allowed to record as unknown.
        @client ||= Github::Client.new(max_retries: 0, rate_limit_retries: 0)
      end
    end
  end
end
