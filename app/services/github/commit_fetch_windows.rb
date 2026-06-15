module Github
  module CommitFetchWindows
    module_function

    def current_week(today: utc_today)
      start_date = Github::BuilderWeeklyAggregator.week_start_for(today)
      start_date..today
    end

    def last_week(today: utc_today)
      current_start = Github::BuilderWeeklyAggregator.week_start_for(today)
      (current_start - Github::BuilderWeeklyAggregator::WEEK_LENGTH_DAYS)..(current_start - 1.day)
    end

    def last_year(today: utc_today)
      last_week_range = last_week(today: today)
      (last_week_range.begin - (51 * Github::BuilderWeeklyAggregator::WEEK_LENGTH_DAYS))..last_week_range.end
    end

    def last_five_years(today: utc_today)
      Github::BuilderWeeklyAggregator::REPORT_START_DATE..last_week(today: today).end
    end

    def utc_today
      Time.now.utc.to_date
    end
  end
end
