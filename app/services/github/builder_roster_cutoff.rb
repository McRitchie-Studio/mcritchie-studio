module Github
  class BuilderRosterCutoff
    DEFAULT_RANGE_LIMIT = 13

    def initialize(range_limit: DEFAULT_RANGE_LIMIT)
      @range_limit = [range_limit.to_i, 1].max
    end

    def apply!(cutoff_login:)
      cutoff_login = cutoff_login.to_s.strip.downcase
      raise ArgumentError, "cutoff_login is required" if cutoff_login.blank?

      ranked_builders = ranked_active_builders
      cutoff_index = ranked_builders.index { |builder| builder.github_login == cutoff_login }
      raise ActiveRecord::RecordNotFound, "Builder not found in active roster: #{cutoff_login}" if cutoff_index.nil?

      included_builders = ranked_builders.first(cutoff_index + 1)
      excluded_builders = ranked_builders.drop(cutoff_index + 1)

      Builder.where(id: included_builders.map(&:id)).update_all(included_in_roster: true, updated_at: Time.current)
      Builder.where(id: excluded_builders.map(&:id)).update_all(included_in_roster: false, updated_at: Time.current)

      {
        cutoff_login: cutoff_login,
        cutoff_rank: cutoff_index + 1,
        cutoff_total_commits: totals_by_login[cutoff_login].to_i,
        included_count: included_builders.size,
        excluded_count: excluded_builders.size,
        range_count: ranges.size,
        range_start_date: ranges.last&.week_start_date,
        range_end_date: ranges.first&.week_end_date
      }
    end

    private

    def ranked_active_builders
      @ranked_active_builders ||= Builder.active.includes(:person).to_a.sort_by do |builder|
        [-totals_by_login[builder.github_login].to_i, builder.display_name.downcase, builder.github_login]
      end
    end

    def totals_by_login
      @totals_by_login ||= GithubBuilderCommitRangeCache
        .where(github_commit_range: ranges)
        .group(:github_login)
        .sum(:commits_count)
    end

    def ranges
      @ranges ||= GithubCommitRange
        .where(week_start_date: Github::BuilderWeeklyAggregator::REPORT_START_DATE..)
        .recent
        .to_a
        .select { |range| range.week_start_date.saturday? }
        .first(@range_limit)
    end
  end
end
