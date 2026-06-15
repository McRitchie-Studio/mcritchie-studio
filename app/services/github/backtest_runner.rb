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

    def run!(start_date:, end_date:, github_logins: nil)
      start_date = parse_date(start_date)
      end_date = parse_date(end_date)
      fetch_start_date = start_date - BASELINE_WARMUP_DAYS
      fetch_results = {}
      builder_scope = TrackedGithubBuilder.active.order(:cohort, :github_login)
      builder_scope = builder_scope.where(github_login: normalize_logins(github_logins)) if github_logins.present?

      builder_scope.find_each do |builder|
        @logger&.info("AI Builder Multiple fetching login=#{builder.github_login}")
        begin
          fetch_results[builder.github_login] = @fetcher.fetch_for_builder(
            builder: builder,
            start_date: fetch_start_date,
            end_date: end_date
          )
        rescue Github::Client::HttpError => e
          @logger&.warn("AI Builder Multiple fetch failed login=#{builder.github_login} error=#{e.class}: #{e.message}")
          fetch_results[builder.github_login] = {
            strategy: "failed",
            stored: 0,
            error: e.message
          }
        end
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

    def normalize_logins(logins)
      Array(logins).flat_map { |login| login.to_s.split(",") }
        .map { |login| login.strip.downcase }
        .reject(&:blank?)
    end
  end
end
