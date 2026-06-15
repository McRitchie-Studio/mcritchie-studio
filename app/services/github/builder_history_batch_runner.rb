module Github
  class BuilderHistoryBatchRunner
    DEFAULT_BATCH_SIZE = 10

    def initialize(fetcher: Github::CommitFetcher.new,
      aggregator: Github::BuilderWeeklyAggregator.new,
      logger: Rails.logger,
      sleeper: ->(seconds) { sleep(seconds) },
      reporter: nil,
      builder_pause_seconds: ENV.fetch("GITHUB_BUILDER_PAUSE_SECONDS", 0).to_f)
      @fetcher = fetcher
      @aggregator = aggregator
      @logger = logger
      @sleeper = sleeper
      @reporter = reporter
      @builder_pause_seconds = builder_pause_seconds.to_f
    end

    def run!(today: Github::CommitFetchWindows.utc_today,
      batch_size: DEFAULT_BATCH_SIZE,
      cohort: nil,
      start_after: nil,
      github_logins: nil,
      skip_complete: true)
      window = Github::CommitFetchWindows.last_five_years(today: today)
      week_starts = Github::BuilderWeeklyAggregator.week_starts_between(window.begin, window.end)
      eligible_builders = eligible_builders(
        week_starts: week_starts,
        cohort: cohort,
        start_after: start_after,
        github_logins: github_logins,
        skip_complete: skip_complete
      )
      builders = eligible_builders.first(normalize_batch_size(batch_size))
      results = {}

      report(
        "AI Builder Multiple five-year batch selected #{builders.size} " \
        "of #{eligible_builders.size} eligible builders"
      )

      builders.each_with_index do |builder, index|
        results[builder.github_login] = fetch_builder(builder, window, week_starts, index + 1, builders.size)
        sleep_between_builders if index < builders.size - 1
      end

      {
        window_start: window.begin,
        window_end: window.end,
        week_count: week_starts.size,
        selected_logins: builders.map(&:github_login),
        next_start_after: builders.last&.github_login,
        eligible_count: eligible_builders.size,
        remaining_after_batch: [eligible_builders.size - builders.size, 0].max,
        results: results
      }
    end

    private

    def eligible_builders(week_starts:, cohort:, start_after:, github_logins:, skip_complete:)
      scope = TrackedGithubBuilder.active.order(:github_login)
      scope = scope.where(cohort: cohort) if cohort.present?
      scope = scope.where("github_login > ?", normalize_login(start_after)) if start_after.present?
      scope = scope.where(github_login: normalize_logins(github_logins)) if github_logins.present?

      builders = scope.to_a
      return builders unless ActiveModel::Type::Boolean.new.cast(skip_complete)

      builders.reject { |builder| complete_cache?(builder, week_starts) }
    end

    def fetch_builder(builder, window, week_starts, position, total)
      started_at = Time.current
      report("AI Builder Multiple fetching #{position}/#{total} login=#{builder.github_login}")

      fetch_result = fetch_with_segment_cache(builder, window)
      cache_summary = cache_summary(builder, week_starts)
      elapsed_seconds = (Time.current - started_at).round(2)
      report(
        "AI Builder Multiple fetched login=#{builder.github_login} " \
        "stored=#{fetch_result[:stored].to_i} cache_rows=#{cache_summary[:cache_rows]} " \
        "commits=#{cache_summary[:total_cached_commits]} elapsed=#{elapsed_seconds}s"
      )
      fetch_result.merge(cache_summary).merge(elapsed_seconds: elapsed_seconds)
    rescue Github::Client::HttpError => e
      elapsed_seconds = (Time.current - started_at).round(2)
      report("AI Builder Multiple fetch failed login=#{builder.github_login} error=#{e.class}: #{e.message}")
      {
        strategy: "failed",
        stored: 0,
        error: e.message,
        elapsed_seconds: elapsed_seconds
      }
    end

    def fetch_with_segment_cache(builder, window)
      segment_index = 0
      segment_cache = lambda do |segment_start, segment_end|
        segment_index += 1
        @aggregator.aggregate!(
          start_date: segment_start,
          end_date: segment_end,
          github_logins: builder.github_login
        )
        report(
          "  cached segment #{segment_index} login=#{builder.github_login} " \
          "#{segment_start}..#{segment_end}"
        )
      end

      fetch_result = @fetcher.fetch_for_builder(
        builder: builder,
        start_date: window.begin,
        end_date: window.end,
        after_segment: segment_cache
      )
      @aggregator.aggregate!(
        start_date: window.begin,
        end_date: window.end,
        github_logins: builder.github_login
      )
      fetch_result
    end

    def complete_cache?(builder, week_starts)
      GithubBuilderCommitRangeCache
        .joins(:github_commit_range)
        .where(tracked_github_builder: builder)
        .where(github_commit_ranges: { week_start_date: week_starts })
        .distinct
        .count(:github_commit_range_id) >= week_starts.size
    end

    def cache_summary(builder, week_starts)
      caches = GithubBuilderCommitRangeCache
        .joins(:github_commit_range)
        .where(tracked_github_builder: builder)
        .where(github_commit_ranges: { week_start_date: week_starts })
      {
        cache_rows: caches.distinct.count(:github_commit_range_id),
        total_cached_commits: caches.sum(:commits_count),
        non_merge_commits: caches.sum(:non_merge_commits_count),
        bot_adjusted_commits: caches.sum(:bot_adjusted_commits_count),
        complete: caches.distinct.count(:github_commit_range_id) >= week_starts.size
      }
    end

    def normalize_batch_size(value)
      [value.to_i, 1].max
    end

    def normalize_logins(logins)
      Array(logins).flat_map { |login| login.to_s.split(",") }
        .map { |login| normalize_login(login) }
        .reject(&:blank?)
    end

    def normalize_login(login)
      login.to_s.strip.downcase
    end

    def sleep_between_builders
      @sleeper.call(@builder_pause_seconds) if @builder_pause_seconds.positive?
    end

    def report(message)
      @reporter&.call(message)
      @logger&.info(message)
    end
  end
end
