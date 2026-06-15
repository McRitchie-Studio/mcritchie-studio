module Github
  class BacktestRunner
    BASELINE_WARMUP_DAYS = 90

    def initialize(fetcher: Github::CommitFetcher.new,
      aggregator: Github::BuilderWeeklyAggregator.new,
      calculator: Github::BuilderIndexCalculator.new,
      exporter: Github::BacktestCsvExporter.new,
      logger: Rails.logger)
      @fetcher = fetcher
      @aggregator = aggregator
      @calculator = calculator
      @exporter = exporter
      @logger = logger
    end

    def run!(start_date:, end_date:)
      start_date = parse_date(start_date)
      end_date = parse_date(end_date)
      fetch_start_date = start_date - BASELINE_WARMUP_DAYS
      fetch_results = {}

      TrackedGithubBuilder.active.order(:cohort, :github_login).find_each do |builder|
        @logger&.info("AI Builder Multiple fetching login=#{builder.github_login}")
        fetch_results[builder.github_login] = @fetcher.fetch_for_builder(
          builder: builder,
          start_date: fetch_start_date,
          end_date: end_date
        )
      end

      weekly_metrics_count = @aggregator.aggregate!(start_date: start_date, end_date: end_date)
      index_weeks_count = @calculator.calculate!(start_date: start_date, end_date: end_date)
      export_paths = @exporter.export!(start_date: start_date, end_date: end_date)

      {
        start_date: start_date,
        end_date: end_date,
        fetch_start_date: fetch_start_date,
        fetch_results: fetch_results,
        weekly_metrics_count: weekly_metrics_count,
        index_weeks_count: index_weeks_count,
        export_paths: export_paths
      }
    end

    private

    def parse_date(value)
      value.is_a?(Date) ? value : Date.parse(value.to_s)
    end
  end
end
