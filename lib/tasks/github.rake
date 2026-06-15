namespace :github do
  namespace :ai_builder_multiple do
    desc "Run the AI Builder Multiple backtest. START=2025-06-01 END=2026-06-01 [MIN_COHORT_SIZE=5] [LOGIN=github_login]"
    task backtest: :environment do
      start_date = ENV.fetch("START") do
        abort "START is required, for example START=2025-06-01"
      end
      end_date = ENV.fetch("END") do
        abort "END is required, for example END=2026-06-01"
      end

      minimum_cohort_size = ENV.fetch("MIN_COHORT_SIZE", Github::BuilderIndexCalculator::DEFAULT_MINIMUM_COHORT_SIZE).to_i
      runner = Github::BacktestRunner.new(
        calculator: Github::BuilderIndexCalculator.new(minimum_cohort_size: minimum_cohort_size)
      )
      result = runner.run!(
        start_date: start_date,
        end_date: end_date,
        github_logins: ENV["LOGIN"].presence || ENV["LOGINS"].presence
      )

      puts "AI Builder Multiple backtest complete"
      puts "  target window: #{result[:start_date]} to #{result[:end_date]}"
      puts "  fetch window:  #{result[:fetch_start_date]} to #{result[:end_date]} (includes 90-day baseline warmup)"
      puts "  builders fetched: #{result[:fetch_results].size}"
      puts "  weekly metric rows written: #{result[:weekly_metrics_count]}"
      puts "  index week rows written: #{result[:index_weeks_count]}"
      puts "  CSV exports:"
      result[:export_paths].each_value { |path| puts "    #{path}" }
    end
  end
end
