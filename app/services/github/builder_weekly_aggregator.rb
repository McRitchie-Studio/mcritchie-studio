require "bigdecimal"

module Github
  class BuilderWeeklyAggregator
    BASELINE_DAYS = 90

    def aggregate!(start_date:, end_date:)
      start_date = parse_date(start_date)
      end_date = parse_date(end_date)
      weeks = self.class.week_starts_between(start_date, end_date)
      count = 0

      TrackedGithubBuilder.active.find_each do |builder|
        observations = observations_for(builder, weeks.first - BASELINE_DAYS, end_date)

        weeks.each do |week_start|
          upsert_metric(builder, week_start, end_date, observations)
          count += 1
        end
      end

      count
    end

    def self.week_start_for(value)
      value.to_date.beginning_of_week(:monday)
    end

    def self.week_starts_between(start_date, end_date)
      current = week_start_for(start_date)
      final = week_start_for(end_date)
      weeks = []
      while current <= final
        weeks << current
        current += 7
      end
      weeks
    end

    private

    def upsert_metric(builder, week_start, end_date, observations)
      target_end = [week_start + 7, end_date + 1].min
      target = select_between(observations, week_start, target_end)
      baseline = select_between(observations, week_start - BASELINE_DAYS, week_start)

      non_merge_count = target.count { |observation| !observation.is_merge? }
      bot_adjusted_count = target.count { |observation| !observation.is_merge? && !observation.is_bot? }
      baseline_non_merge_count = baseline.count { |observation| !observation.is_merge? }
      baseline_bot_adjusted_count = baseline.count { |observation| !observation.is_merge? && !observation.is_bot? }

      baseline_avg = weekly_average(baseline_non_merge_count)
      bot_baseline_avg = weekly_average(baseline_bot_adjusted_count)
      active_repos_count = target.map(&:repo_full_name).uniq.size
      trailing_average = decimal(baseline_avg)
      builder_multiple = multiple(non_merge_count, baseline_avg)
      bot_adjusted_builder_multiple = multiple(bot_adjusted_count, bot_baseline_avg)

      metric = GithubBuilderWeeklyMetric.find_or_initialize_by(
        github_login: builder.github_login,
        week_start_date: week_start
      )
      metric.assign_attributes(
        cohort: builder.cohort,
        commits_count: target.size,
        non_merge_commits_count: non_merge_count,
        bot_adjusted_commits_count: bot_adjusted_count,
        active_repos_count: active_repos_count,
        trailing_90d_avg_weekly_commits: trailing_average,
        builder_multiple: builder_multiple,
        bot_adjusted_builder_multiple: bot_adjusted_builder_multiple
      )
      metric.save!

      upsert_range_cache(
        builder: builder,
        week_start: week_start,
        target: target,
        non_merge_count: non_merge_count,
        bot_adjusted_count: bot_adjusted_count,
        active_repos_count: active_repos_count,
        trailing_average: trailing_average,
        builder_multiple: builder_multiple,
        bot_adjusted_builder_multiple: bot_adjusted_builder_multiple
      )
    end

    def upsert_range_cache(builder:, week_start:, target:, non_merge_count:, bot_adjusted_count:, active_repos_count:, trailing_average:, builder_multiple:, bot_adjusted_builder_multiple:)
      range = GithubCommitRange.for_week_start(week_start)
      cache = GithubBuilderCommitRangeCache.find_or_initialize_by(
        tracked_github_builder: builder,
        github_commit_range: range
      )
      cache.assign_attributes(
        github_login: builder.github_login,
        cohort: builder.cohort,
        commits_count: target.size,
        non_merge_commits_count: non_merge_count,
        bot_adjusted_commits_count: bot_adjusted_count,
        active_repos_count: active_repos_count,
        trailing_90d_avg_weekly_commits: trailing_average,
        builder_multiple: builder_multiple,
        bot_adjusted_builder_multiple: bot_adjusted_builder_multiple,
        commit_shas: target.sort_by { |observation| [observation.observed_at, observation.sha] }.map(&:sha),
        cached_at: Time.current
      )
      cache.save!
    end

    def observations_for(builder, start_date, end_date)
      start_time = start_date.beginning_of_day
      end_time = end_date.end_of_day

      GithubCommitObservation.for_login(builder.github_login)
        .where(
          "(committed_at >= ? AND committed_at <= ?) OR " \
          "(committed_at IS NULL AND authored_at >= ? AND authored_at <= ?)",
          start_time, end_time, start_time, end_time
        )
        .to_a
        .select(&:observed_at)
        .then { |observations| dedupe_observations(observations) }
    end

    def select_between(observations, start_date, end_date)
      observations.select do |observation|
        observed_date = observation.observed_at.to_date
        observed_date >= start_date && observed_date < end_date
      end
    end

    def weekly_average(count)
      count.to_f / (BASELINE_DAYS.to_f / 7.0)
    end

    def multiple(count, baseline_avg)
      return nil unless baseline_avg&.positive?

      decimal(count.to_f / baseline_avg)
    end

    def decimal(value)
      return nil if value.nil?

      BigDecimal(value.to_s).round(4)
    end

    def parse_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end

    def dedupe_observations(observations)
      observations
        .sort_by { |observation| [observation.sha, source_priority(observation.source_strategy), observation.id || 0] }
        .uniq(&:sha)
    end

    def source_priority(source_strategy)
      source_strategy == "repo_scoped" ? 0 : 1
    end
  end
end
