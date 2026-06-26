module Github
  class BuilderHistoryBatchRunner
    DEFAULT_BATCH_SIZE = 10

    def initialize(fetcher: Github::CommitFetcher.new,
      aggregator: Github::BuilderWeeklyAggregator.new,
      logger: Rails.logger,
      sleeper: ->(seconds) { sleep(seconds) },
      reporter: nil,
      builder_pause_seconds: ENV.fetch("GITHUB_BUILDER_PAUSE_SECONDS", 0).to_f,
      cache_key: nil)
      @fetcher = fetcher
      @aggregator = aggregator
      @logger = logger
      @sleeper = sleeper
      @reporter = reporter
      @builder_pause_seconds = builder_pause_seconds.to_f
      @cache_key = cache_key.presence || aggregator_cache_key(aggregator)
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
        "of #{eligible_builders.size} eligible builders cache_key=#{@cache_key}"
      )

      builders.each_with_index do |builder, index|
        results[builder.github_login] = fetch_builder(builder, window, week_starts, index + 1, builders.size)
        sleep_between_builders if index < builders.size - 1
      end

      {
        window_start: window.begin,
        window_end: window.end,
        week_count: week_starts.size,
        cache_key: @cache_key,
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
      pruned_observations = prune_observations_if_complete(builder, cache_summary)
      elapsed_seconds = (Time.current - started_at).round(2)
      report(
        "AI Builder Multiple fetched login=#{builder.github_login} " \
        "stored=#{fetch_result[:stored].to_i} cache_rows=#{cache_summary[:cache_rows]} " \
        "commits=#{cache_summary[:total_cached_commits]} pruned=#{pruned_observations} " \
        "elapsed=#{elapsed_seconds}s"
      )
      fetch_result.merge(cache_summary).merge(pruned_observations: pruned_observations, elapsed_seconds: elapsed_seconds)
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
        .for_cache_key(@cache_key)
        .where(tracked_github_builder: builder)
        .where(github_commit_ranges: { week_start_date: week_starts })
        .distinct
        .count(:github_commit_range_id) >= week_starts.size
    end

    def cache_summary(builder, week_starts)
      caches = GithubBuilderCommitRangeCache
        .joins(:github_commit_range)
        .for_cache_key(@cache_key)
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

    # Observations are a disposable staging area: once every week in the window is
    # cached (metrics + commit_shas persisted in GithubBuilderCommitRangeCache),
    # the raw rows are no longer read. Prune them so the table can't grow unbounded
    # (root cause of the 2026-06-25 outage). Gated on a COMPLETE cache so we never
    # delete history the trailing-90-day baseline still needs mid-run; a re-run
    # simply re-fetches from GitHub.
    def prune_observations_if_complete(builder, cache_summary)
      return 0 unless cache_summary[:complete]

      scope = GithubCommitObservation.for_login(builder.github_login)
      # Persist the day-granular observed-through watermark BEFORE deleting, so the
      # dashboard keeps its partial-week boundary protection once the staging rows
      # are gone (the weekly caches are too coarse to reconstruct it).
      GithubObservationWindow.advance_to(scope.maximum(:committed_at))
      deleted = scope.delete_all
      report("  pruned #{deleted} staged observations login=#{builder.github_login}") if deleted.positive?
      deleted
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

    def aggregator_cache_key(aggregator)
      return aggregator.cache_key if aggregator.respond_to?(:cache_key)

      Github::CommitCacheKey.current
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
