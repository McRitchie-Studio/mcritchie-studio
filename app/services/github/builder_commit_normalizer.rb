module Github
  class BuilderCommitNormalizer
    SCORE_LEVELS = [1, 2, 3, 5, 8].freeze
    DEFAULT_MIN_HISTORY_RANGES = 13

    def initialize(history_start_date: Github::BuilderWeeklyAggregator::REPORT_START_DATE,
      history_end_date: Date.current,
      min_history_ranges: DEFAULT_MIN_HISTORY_RANGES)
      @history_start_date = history_start_date.to_date
      @history_end_date = history_end_date.to_date
      @min_history_ranges = [min_history_ranges.to_i, 1].max
    end

    def scores_for(caches:)
      cache_list = Array(caches).compact
      return {} if cache_list.blank?

      history_by_builder_id = history_counts_for(cache_list.map(&:tracked_github_builder_id).compact.uniq)

      cache_list.each_with_object({}) do |cache, scores|
        scores[cache.id] = score_for(
          count: cache.commits_count,
          history_counts: history_by_builder_id[cache.tracked_github_builder_id]
        )
      end
    end

    def score_for(count:, history_counts:)
      counts = Array(history_counts).compact.map(&:to_i)
      return nil if counts.size < @min_history_ranges

      commits_count = [count.to_i, 0].max
      percentile = counts.count { |historical_count| historical_count < commits_count }.to_f / counts.size

      case percentile
      when 0...0.2 then 1
      when 0.2...0.4 then 2
      when 0.4...0.6 then 3
      when 0.6...0.8 then 5
      else 8
      end
    end

    private

    def history_counts_for(tracked_builder_ids)
      return {} if tracked_builder_ids.blank?

      GithubBuilderCommitRangeCache
        .joins(:github_commit_range)
        .where(tracked_github_builder_id: tracked_builder_ids)
        .where(github_commit_ranges: { week_start_date: @history_start_date..@history_end_date })
        .pluck(:tracked_github_builder_id, :commits_count)
        .each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(tracked_builder_id, commits_count), history|
          history[tracked_builder_id] << commits_count.to_i
        end
    end
  end
end
