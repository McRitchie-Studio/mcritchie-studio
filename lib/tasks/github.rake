namespace :github do
  namespace :ai_builder_multiple do
    desc "Run the AI Builder Multiple backtest. START=2025-06-01 END=2026-06-01 [MIN_COHORT_SIZE=5] [LOGIN=github_login] [SKIP_FETCH=1]"
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
        github_logins: ENV["LOGIN"].presence || ENV["LOGINS"].presence,
        skip_fetch: ActiveModel::Type::Boolean.new.cast(ENV["SKIP_FETCH"])
      )

      puts "AI Builder Multiple backtest complete"
      puts "  target window: #{result[:start_date]} to #{result[:end_date]}"
      puts "  fetch window:  #{result[:fetch_start_date]} to #{result[:end_date]} (includes 90-day baseline warmup)"
      puts "  fetch skipped: #{result[:fetch_skipped]}"
      puts "  builders fetched: #{result[:fetch_results].size}"
      puts "  weekly metric rows written: #{result[:weekly_metrics_count]}"
      puts "  index week rows written: #{result[:index_weeks_count]}"
      puts "  CSV exports:"
      result[:export_paths].each_value { |path| puts "    #{path}" }
    end

    desc "Import Paul Miller's historic active GitHub users gist as control candidates. [MAX=910] [ACTIVE=true]"
    task import_paulmillr_active_users: :environment do
      importer = Github::PaulMillrActiveUsersImporter.new
      result = importer.import!(
        url: ENV.fetch("URL", Github::PaulMillrActiveUsersImporter::DEFAULT_URL),
        cohort: ENV.fetch("COHORT", "control_builder"),
        active: ActiveModel::Type::Boolean.new.cast(ENV.fetch("ACTIVE", "true")),
        max: ENV.fetch("MAX", 910)
      )

      puts "Paul Miller active GitHub users import complete"
      puts "  source: #{result[:source_url]}"
      puts "  rows seen: #{result[:seen]}"
      puts "  created: #{result[:created]}"
      puts "  updated: #{result[:updated]}"
      puts "  existing preserved: #{result[:existing_preserved]}"
    end
  end
end
