module Github
  class BacktestRunner
    BASELINE_WARMUP_DAYS = 90

    def initialize(fetcher: Github::CommitFetcher.new,
      aggregator: Github::BuilderWeeklyAggregator.new,
      calculator: Github::BuilderIndexCalculator.new,
      exporter: Github::BacktestCsvExporter.new,
      logger: Rails.logger,
      sleeper: ->(seconds) { sleep(seconds) },
      builder_pause_seconds: ENV.fetch("GITHUB_BUILDER_PAUSE_SECONDS", 0).to_f,
      rate_limit_pause_seconds: ENV.fetch("GITHUB_RATE_LIMIT_PAUSE_SECONDS", 60).to_f,
      rate_limit_retries: ENV.fetch("GITHUB_RATE_LIMIT_RETRIES", 1).to_i)
      @fetcher = fetcher
      @aggregator = aggregator
      @calculator = calculator
      @exporter = exporter
      @logger = logger
      @sleeper = sleeper
      @builder_pause_seconds = builder_pause_seconds.to_f
      @rate_limit_pause_seconds = rate_limit_pause_seconds.to_f
      @rate_limit_retries = rate_limit_retries.to_i
    end

    def run!(start_date:, end_date:, github_logins: nil, skip_fetch: false, fetch_warmup_days: BASELINE_WARMUP_DAYS)
      start_date = parse_date(start_date)
      end_date = parse_date(end_date)
      fetch_start_date = start_date - fetch_warmup_days.to_i
      fetch_results = {}
      builder_scope = TrackedGithubBuilder.active.order(:cohort, :github_login)
      builder_scope = builder_scope.where(github_login: normalize_logins(github_logins)) if github_logins.present?

      unless skip_fetch
        builder_count = builder_scope.count
        builder_scope.find_each.with_index do |builder, index|
          @logger&.info("AI Builder Multiple fetching login=#{builder.github_login}")
          begin
            fetch_results[builder.github_login] = fetch_with_rate_limit_retry(builder, fetch_start_date, end_date)
          rescue Github::Client::HttpError => e
            @logger&.warn("AI Builder Multiple fetch failed login=#{builder.github_login} error=#{e.class}: #{e.message}")
            fetch_results[builder.github_login] = {
              strategy: "failed",
              stored: 0,
              error: e.message
            }
          end
          sleep_between_builders if index < builder_count - 1
        end
      end

      weekly_metrics_count = @aggregator.aggregate!(start_date: start_date, end_date: end_date)
      index_weeks_count = @calculator.calculate!(start_date: start_date, end_date: end_date)
      export_paths = @exporter.export!(start_date: start_date, end_date: end_date)

      {
        start_date: start_date,
        end_date: end_date,
        fetch_start_date: fetch_start_date,
        fetch_warmup_days: fetch_warmup_days.to_i,
        fetch_skipped: skip_fetch,
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

    def fetch_with_rate_limit_retry(builder, start_date, end_date)
      attempts = 0

      begin
        @fetcher.fetch_for_builder(
          builder: builder,
          start_date: start_date,
          end_date: end_date
        )
      rescue Github::Client::RateLimitError => e
        raise if attempts >= @rate_limit_retries || @rate_limit_pause_seconds <= 0

        attempts += 1
        @logger&.warn(
          "AI Builder Multiple rate limited login=#{builder.github_login} " \
          "retry=#{attempts}/#{@rate_limit_retries} sleep=#{@rate_limit_pause_seconds}s error=#{e.message}"
        )
        @sleeper.call(@rate_limit_pause_seconds)
        retry
      end
    end

    def sleep_between_builders
      @sleeper.call(@builder_pause_seconds) if @builder_pause_seconds.positive?
    end
  end
end
