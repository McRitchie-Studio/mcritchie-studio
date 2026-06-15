namespace :github do
  namespace :ai_builder_multiple do
    parse_today = -> {
      ENV["TODAY"].present? ? Date.parse(ENV["TODAY"]) : Github::CommitFetchWindows.utc_today
    }

    run_fetch_window = ->(label, window) {
      minimum_cohort_size = ENV.fetch("MIN_COHORT_SIZE", Github::BuilderIndexCalculator::DEFAULT_MINIMUM_COHORT_SIZE).to_i
      fetch_warmup_days = ENV.fetch("FETCH_WARMUP_DAYS", 0).to_i
      runner = Github::BacktestRunner.new(
        calculator: Github::BuilderIndexCalculator.new(minimum_cohort_size: minimum_cohort_size)
      )
      result = runner.run!(
        start_date: window.begin,
        end_date: window.end,
        github_logins: ENV["LOGIN"].presence || ENV["LOGINS"].presence,
        fetch_warmup_days: fetch_warmup_days
      )

      puts "AI Builder Multiple #{label} fetch complete"
      puts "  target window: #{result[:start_date]} to #{result[:end_date]}"
      puts "  fetch window:  #{result[:fetch_start_date]} to #{result[:end_date]}"
      puts "  fetch warmup days: #{result[:fetch_warmup_days]}"
      puts "  builders fetched: #{result[:fetch_results].size}"
      puts "  weekly metric rows written: #{result[:weekly_metrics_count]}"
      puts "  index week rows written: #{result[:index_weeks_count]}"
      puts "  pacing:"
      puts "    GITHUB_REQUEST_PAUSE_SECONDS=#{ENV.fetch("GITHUB_REQUEST_PAUSE_SECONDS", 0)}"
      puts "    GITHUB_BUILDER_PAUSE_SECONDS=#{ENV.fetch("GITHUB_BUILDER_PAUSE_SECONDS", 0)}"
      puts "    GITHUB_RATE_LIMIT_PAUSE_SECONDS=#{ENV.fetch("GITHUB_RATE_LIMIT_PAUSE_SECONDS", 60)}"
      puts "    GITHUB_RATE_LIMIT_RETRIES=#{ENV.fetch("GITHUB_RATE_LIMIT_RETRIES", 1)}"
      puts "  CSV exports:"
      result[:export_paths].each_value { |path| puts "    #{path}" }
    }

    desc "Run the AI Builder Multiple backtest. START=2021-07-24 END=2026-06-12 [MIN_COHORT_SIZE=5] [LOGIN=github_login] [SKIP_FETCH=1]"
    task backtest: :environment do
      start_date = ENV.fetch("START") do
        abort "START is required, for example START=2021-07-24"
      end
      end_date = ENV.fetch("END") do
        abort "END is required, for example END=2026-06-12"
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

    desc "Fetch tracked builder commits for the last complete Saturday-Friday UTC week. [LOGIN=github_login] [GITHUB_REQUEST_PAUSE_SECONDS=0] [GITHUB_BUILDER_PAUSE_SECONDS=0]"
    task fetch_last_week: :environment do
      run_fetch_window.call("last week", Github::CommitFetchWindows.last_week(today: parse_today.call))
    end

    desc "Fetch tracked builder commits from 2021-07-24 through the last complete Saturday-Friday UTC week. [LOGIN=github_login] [GITHUB_REQUEST_PAUSE_SECONDS=0] [GITHUB_BUILDER_PAUSE_SECONDS=0]"
    task fetch_last_five_years: :environment do
      run_fetch_window.call("last five years", Github::CommitFetchWindows.last_five_years(today: parse_today.call))
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
