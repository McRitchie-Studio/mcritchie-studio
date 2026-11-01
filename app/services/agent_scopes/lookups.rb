# frozen_string_literal: true

require Rails.root.join("bin/lib/agent_scope").to_s

module AgentScopes
  # The board reads a SCOPED run may make (docs/agents/system/agent-message-loop.md,
  # "Scoped runs: the owner's terminal in Slack"). The catalog, the params and
  # their bounds are AgentMailbox::Scopes::LOOKUPS (bin/lib/agent_scope.rb), which
  # the dispatcher's tool server checks too; this module runs them.
  #
  # CODE, never model-written SQL: each lookup is a fixed query with bounded
  # params and a row cap, formatted as plain text for the model to reason over.
  # Nothing here writes. Satellites are read only through their health endpoint
  # (DailyAppReport.health_for), whose error messages the engine already
  # redacts; every answer is scrubbed once more (AgentMailbox::Redact) on the
  # way out.
  module Lookups
    Scopes = AgentMailbox::Scopes
    # The most rows any one list shows.
    ROWS = 15
    MESSAGE_LIMIT = 160
    # A satellite's health read inside a lookup: short, because the whole
    # answer must come back inside the router's 30 seconds.
    FETCH_OPEN = 3
    FETCH_READ = 8
    FETCH_THREADS = 6

    class Unavailable < StandardError; end

    module_function

    # The text for one checked lookup. `params` were checked by
    # Scopes.check_lookup (defaults filled).
    def run(name, params, now: Time.current, fetcher: nil, env: ENV, books: nil)
      text = case name
             when "error_groups" then error_groups(days: params.fetch("days"), app: params["app"], now: now,
                                                   fetcher: fetcher, env: env)
             when "gate_failures" then gate_failures(days: params.fetch("days"), now: now)
             when "review_findings" then review_findings(limit: params.fetch("limit"))
             when "grades" then grades(days: params.fetch("days"), now: now)
             when "board_status" then AgentProposals::Queries.board_status
             when "recently_shipped" then AgentProposals::Queries.recently_shipped(days: params.fetch("days"), now: now)
             when "release_status" then AgentProposals::Queries.release_status
             when "books_status" then books_status(params.fetch("entity"), config: books || Books::Config.current)
             when "books_unclassified" then books_unclassified(params.fetch("entity"), limit: params.fetch("limit"),
                                                                                      config: books || Books::Config.current)
             when "books_month" then books_month(params.fetch("entity"), params.fetch("month"), config: books || Books::Config.current)
             when "usage" then AgentProposals::Queries.usage(params.fetch("app"), now: now)
             else raise Scopes::Refused, "no lookup named #{name.to_s[0, 40].inspect}"
             end
      AgentMailbox::Redact.call(text)
    rescue AgentProposals::Queries::Unavailable, Books::Config::Error => e
      raise Unavailable, e.message
    end

    # ---- Mason ---------------------------------------------------------------

    # Every live app's health report over `days` daily windows, summed per
    # (app, error class, message): the hub in process, each satellite over its
    # endpoint, read in parallel with short timeouts. Apps that could not be read
    # are named, so a quiet app and an unread one never look the same.
    def error_groups(days:, app:, now:, fetcher:, env:)
      apps = DailyAppReport.apps
      apps = apps.select { |a| a.slug == app } if app
      raise Unavailable, "#{app.inspect} is not a live app with a health report" if app && apps.empty?

      fetcher ||= DailyAppReport::Fetcher.new(open_timeout: FETCH_OPEN, read_timeout: FETCH_READ)
      last = DailyAppReport.window_end(now)
      windows = (0...days).map { |i| last - i.days }
      reports = read_health(apps, windows, fetcher: fetcher, env: env)

      groups = Hash.new(0)
      unread = []
      totals = Hash.new(0)
      reports.each do |(target, _ending), health|
        unless health.ok?
          unread << "#{target.name} (#{health.not_wired? ? 'not wired' : health.reason})"
          next
        end
        totals[target.name] += health.error_count
        Array(health.error_groups).each do |g|
          message = g[:message].to_s.squish[0, MESSAGE_LIMIT]
          groups[[ target.name, g[:error_class].to_s, message ]] += g[:count].to_i
        end
      end

      span = days == 1 ? "the day" : "the #{days} days"
      head = "Errors across #{apps.size} app#{'s' unless apps.size == 1}, #{span} to " \
             "#{last.strftime('%b %-d, %-l:%M %p %Z')}: " +
             (totals.empty? ? "no app could be read." : totals.sort_by { |n, c| [ -c, n ] }.map { |n, c| "#{n} #{c}" }.join(", ") + ".")
      lines = groups.sort_by { |(n, k, m), c| [ -c, n, k, m ] }.first(ROWS).map do |(name, klass, message), count|
        "- #{name}: #{klass} ×#{count}#{message.empty? ? '' : " \"#{message}\""}"
      end
      more = groups.size > lines.size ? "\n…and #{groups.size - lines.size} more groups." : ""
      unread_line = unread.uniq.any? ? "\nNot read: #{unread.uniq.join('; ')}." : ""
      body = lines.any? ? "\nMost frequent (app: class ×count \"redacted message\"):\n#{lines.join("\n")}#{more}" : ""
      "#{head}#{body}#{unread_line}"
    end

    # { [app, ending] => AppHealth }. The hub reads its own database on this
    # thread; satellites are HTTP, so they run on a few threads.
    def read_health(apps, windows, fetcher:, env:)
      jobs = apps.product(windows)
      hub, remote = jobs.partition { |(a, _)| a.slug == DailyAppReport::HUB_SLUG }
      out = hub.to_h { |(a, w)| [ [ a, w ], DailyAppReport.health_for(a, w, fetcher: fetcher, env: env) ] }
      queue = Queue.new
      remote.each { |job| queue << job }
      results = Queue.new
      Array.new([ FETCH_THREADS, remote.size ].min) do
        Thread.new do
          # health_for may write an ErrorLog for an app it could not read.
          ActiveRecord::Base.connection_pool.with_connection do
            loop do
              a, w = queue.pop(true)
              results << [ [ a, w ], DailyAppReport.health_for(a, w, fetcher: fetcher, env: env) ]
            rescue ThreadError
              break
            end
          end
        end
      end.each(&:join)
      out.merge!(Array.new(results.size) { results.pop }.to_h)
      out
    end

    # Gate attempts that FINISHED in the window: per gate, attempts and failures;
    # the test SOPs that failed most (by sop and cause); the subjects with the
    # most failed attempts.
    def gate_failures(days:, now:)
      scope = GateRun.where(finished_at: (now - days.days)..now)
      per_gate = scope.group(:key, :success).count
      return "No gate finished in the last #{days} day#{'s' unless days == 1}." if per_gate.empty?

      gate_lines = GateRun::KEYS.filter_map do |key|
        pass = per_gate.fetch([ key, true ], 0)
        fail = per_gate.fetch([ key, false ], 0)
        next if (pass + fail).zero?

        "- #{GateRun::GATES.dig(key, 'label')}: #{pass + fail} attempts, #{fail} failed"
      end
      sops = Hash.new(0)
      scope.where(success: false).limit(500).pluck(:sops).each do |list|
        Array(list).each do |entry|
          next unless entry.is_a?(Hash) && entry["result"].to_s == "fail"

          cause = (entry["cause"].presence || entry["reason"].presence).to_s.squish[0, 80]
          sops[[ entry["sop"].to_s, cause ]] += 1
        end
      end
      sop_lines = sops.sort_by { |(s, c), n| [ -n, s, c ] }.first(ROWS).map do |(sop, cause), n|
        "- #{sop} ×#{n}#{cause.empty? ? '' : " (#{cause})"}"
      end
      subjects = scope.where(success: false).group(:subject_type, :subject_slug).count
                      .sort_by { |(t, s), n| [ -n, t, s ] }.first(ROWS)
                      .map { |(type, slug), n| "- #{type} `#{slug}`: #{n} failed" }
      [ "Gates finished in the last #{days} day#{'s' unless days == 1}:", *gate_lines,
        (sop_lines.any? ? "Failing test SOPs most named:\n#{sop_lines.join("\n")}" : nil),
        (subjects.any? ? "Most failed subjects:\n#{subjects.join("\n")}" : nil) ].compact.join("\n")
    end

    # Open triage findings, newest first, and the tasks blocked now.
    def review_findings(limit:)
      open = TriageFinding.where(status: "open")
      total = open.count
      findings = open.order(created_at: :desc).limit(limit).map do |f|
        "- `#{f.slug}` #{f.title.to_s.squish[0, 100]}#{" [#{f.repo}]" if f.repo.present?}" \
          "#{" (#{f.source})" if f.source.present?}, #{f.created_at.in_time_zone(DailyAppReport::ZONE).strftime('%b %-d')}"
      end
      blocked = Task.where(stage: "building").where.not(blocked_at: nil).order(blocked_at: :desc).limit(limit).map do |t|
        "- `#{t.slug}` #{t.title.to_s.squish[0, 80]} (#{t.block_kind || 'blocked'} since " \
          "#{t.blocked_at.in_time_zone(DailyAppReport::ZONE).strftime('%b %-d')})"
      end
      [ "Open triage findings: #{total}#{" (newest #{findings.size})" if total > findings.size}",
        *findings, "Blocked tasks now: #{blocked.size}", *blocked ].join("\n")
    end

    # Task grades in the window, the thresholds they tripped, the newest
    # learnings, and action grades by disposition.
    def grades(days:, now:)
      window = (now - days.days)..now
      graded = TaskGrade.where(graded_at: window)
      verdicts = graded.group(:verdict).count
      tripped = Hash.new(0)
      graded.limit(500).pluck(:tripped).each do |list|
        Array(list).each do |t|
          key = t.is_a?(Hash) ? (t["key"] || t["threshold"] || t["name"] || t["rule"]).to_s : t.to_s
          tripped[key] += 1 unless key.empty?
        end
      end
      learnings = graded.learnings.order(graded_at: :desc).limit(8).map do |g|
        "- `#{g.task_slug}`: #{g.learning.to_s.squish[0, 200]}"
      end
      actions = ActionGrade.where(created_at: window).group(:disposition).count
      [ "Task grades in the last #{days} days: #{verdicts.map { |v, n| "#{v.tr('_', ' ')} #{n}" }.join(', ').presence || 'none'}.",
        (tripped.any? ? "Tripped most: #{tripped.sort_by { |k, n| [ -n, k ] }.first(ROWS).map { |k, n| "#{k} ×#{n}" }.join(', ')}." : nil),
        (learnings.any? ? "Newest learnings:\n#{learnings.join("\n")}" : nil),
        "Action grades: #{actions.map { |d, n| "#{d} #{n}" }.join(', ').presence || 'none'}." ].compact.join("\n")
    end

    # ---- Mack ----------------------------------------------------------------

    # Books::Export#status read from the database alone: no Drive call, so the
    # Inbox is not listed (bin/books status reads it).
    def books_status(key, config:)
      entity = config.entity(key)
      statements = BookStatement.for_entity(entity.key).order(:period_start).to_a
      accounts = entity.accounts.values.map do |a|
        own = statements.select { |s| s.account_key == a.key }
        "- #{a.label}: #{own.size} statement#{'s' unless own.size == 1}, through #{own.last&.period_end&.iso8601 || '-'}"
      end
      waiting = BookEntry.for_entity(entity.key).unclassified
      closes = BookClose.where(entity: entity.key).order(:month).last(24).map do |c|
        cash = c.summary["cash_cents"] ? " cash #{Books.money(c.summary['cash_cents'])}" : ""
        ytd = c.summary["net_income_ytd_cents"] ? ", net income YTD #{Books.money(c.summary['net_income_ytd_cents'])}" : ""
        "- #{c.month} #{c.status}#{cash}#{ytd}#{", lender package written" if c.lender_sheet_file_id.present?}"
      end
      oldest = waiting.minimum(:posted_on)
      [ "#{entity.name} (#{entity.key}):", *accounts,
        "Lines waiting for an answer: #{waiting.count}#{" (oldest #{oldest.iso8601})" if oldest}",
        "Closes: #{closes.empty? ? 'none yet' : ''}", *closes,
        "(The Drive Inbox is not read here; bin/books status lists it.)" ].join("\n")
    end

    def books_unclassified(key, limit:, config:)
      entity = config.entity(key)
      scope = BookEntry.for_entity(entity.key).unclassified
      total = scope.count
      rows = scope.chronological.limit(limit).map do |e|
        "- ##{e.id} #{e.posted_on.iso8601} #{e.account_key} #{Books.money(e.amount_cents)} #{e.description.to_s.squish[0, 90]}"
      end
      "#{entity.name}: #{total} line#{'s' unless total == 1} waiting for a category" \
        "#{" (oldest #{rows.size} shown)" if total > rows.size}#{rows.any? ? ":\n#{rows.join("\n")}" : '.'}"
    end

    # One month of an entity's ledger: totals per category and per kind, from
    # the lines themselves (a draft month reads the same way a closed one does).
    def books_month(key, month, config:)
      entity = config.entity(key)
      start = Date.strptime("#{month}-01", "%Y-%m-%d")
      lines = BookEntry.for_entity(entity.key).where(posted_on: start..start.end_of_month)
      count = lines.count
      return "#{entity.name}, #{month}: no ledger lines." if count.zero?

      by_category = lines.group(:category).sum(:amount_cents)
      kinds = Hash.new(0)
      rows = by_category.sort_by { |c, cents| [ c.nil? ? 1 : 0, cents ] }.map do |category, cents|
        if category.nil?
          "- unclassified: #{Books.money(cents)}"
        else
          cat = config.category(category)
          kinds[cat.kind] += cents
          "- #{cat.label} (#{cat.kind}): #{Books.money(cents)}"
        end
      end
      close = BookClose.find_by(entity: entity.key, month: month)
      [ "#{entity.name}, #{month}: #{count} line#{'s' unless count == 1}" \
        "#{close ? ", close #{close.status}" : ', not closed'}.",
        "By kind: #{kinds.map { |k, cents| "#{k} #{Books.money(cents)}" }.join(', ').presence || 'nothing classified'}.",
        "By category:", *rows ].join("\n")
    end
  end
end
