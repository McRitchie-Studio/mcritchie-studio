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
      puts "    GITHUB_SEARCH_RANGE_DAYS=#{ENV.fetch("GITHUB_SEARCH_RANGE_DAYS", Github::CommitFetcher::DEFAULT_SEARCH_RANGE_DAYS)}"
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

    desc "Fetch the next batch of tracked builder five-year commit history. [BATCH_SIZE=10] [START_AFTER=github_login] [COHORT=ai_builder|control_builder] [LOGIN=github_login] [SKIP_COMPLETE=true]"
    task fetch_last_five_years_batch: :environment do
      $stdout.sync = true
      batch_size = ENV.fetch("BATCH_SIZE", ENV.fetch("LIMIT", Github::BuilderHistoryBatchRunner::DEFAULT_BATCH_SIZE)).to_i
      runner = Github::BuilderHistoryBatchRunner.new(reporter: ->(message) { puts message })
      result = runner.run!(
        today: parse_today.call,
        batch_size: batch_size,
        cohort: ENV["COHORT"].presence,
        start_after: ENV["START_AFTER"].presence,
        github_logins: ENV["LOGIN"].presence || ENV["LOGINS"].presence,
        skip_complete: ENV.fetch("SKIP_COMPLETE", "true")
      )

      puts "AI Builder Multiple five-year batch complete"
      puts "  window: #{result[:window_start]} to #{result[:window_end]}"
      puts "  weeks per builder: #{result[:week_count]}"
      puts "  selected builders: #{result[:selected_logins].join(", ")}"
      puts "  next START_AFTER: #{result[:next_start_after] || "(none)"}"
      puts "  remaining eligible after batch: #{result[:remaining_after_batch]}"
      puts "  pacing:"
      puts "    GITHUB_SEARCH_RANGE_DAYS=#{ENV.fetch("GITHUB_SEARCH_RANGE_DAYS", Github::CommitFetcher::DEFAULT_SEARCH_RANGE_DAYS)}"
      puts "    GITHUB_REQUEST_PAUSE_SECONDS=#{ENV.fetch("GITHUB_REQUEST_PAUSE_SECONDS", 0)}"
      puts "    GITHUB_BUILDER_PAUSE_SECONDS=#{ENV.fetch("GITHUB_BUILDER_PAUSE_SECONDS", 0)}"
      puts "    GITHUB_RATE_LIMIT_PAUSE_SECONDS=#{ENV.fetch("GITHUB_RATE_LIMIT_PAUSE_SECONDS", 60)}"
      puts "    GITHUB_RATE_LIMIT_RETRIES=#{ENV.fetch("GITHUB_RATE_LIMIT_RETRIES", 1)}"
      result[:results].each do |login, builder_result|
        puts(
          "  #{login}: strategy=#{builder_result[:strategy]} stored=#{builder_result[:stored]} " \
          "cache_rows=#{builder_result[:cache_rows] || 0} commits=#{builder_result[:total_cached_commits] || 0} " \
          "complete=#{builder_result[:complete] || false} elapsed=#{builder_result[:elapsed_seconds]}s"
        )
      end
    end

    desc "Fetch five-year commit history for builders included in the public roster. [BATCH_SIZE=10] [START_AFTER=github_login] [SKIP_COMPLETE=true]"
    task fetch_included_last_five_years_batch: :environment do
      $stdout.sync = true
      logins = Builder.active.included_in_roster.order(:github_login).pluck(:github_login)
      if ENV["START_AFTER"].present?
        start_after = ENV["START_AFTER"].strip.downcase
        logins = logins.select { |login| login > start_after }
      end

      batch_size = ENV.fetch("BATCH_SIZE", ENV.fetch("LIMIT", Github::BuilderHistoryBatchRunner::DEFAULT_BATCH_SIZE)).to_i
      runner = Github::BuilderHistoryBatchRunner.new(reporter: ->(message) { puts message })
      result = runner.run!(
        today: parse_today.call,
        batch_size: batch_size,
        github_logins: logins,
        skip_complete: ENV.fetch("SKIP_COMPLETE", "true")
      )

      puts "AI Builder Multiple included-roster five-year batch complete"
      puts "  window: #{result[:window_start]} to #{result[:window_end]}"
      puts "  weeks per builder: #{result[:week_count]}"
      puts "  included roster candidates after START_AFTER: #{logins.size}"
      puts "  selected builders: #{result[:selected_logins].join(", ")}"
      puts "  next START_AFTER: #{result[:next_start_after] || "(none)"}"
      puts "  remaining eligible after batch: #{result[:remaining_after_batch]}"
      puts "  pacing:"
      puts "    GITHUB_SEARCH_RANGE_DAYS=#{ENV.fetch("GITHUB_SEARCH_RANGE_DAYS", Github::CommitFetcher::DEFAULT_SEARCH_RANGE_DAYS)}"
      puts "    GITHUB_REQUEST_PAUSE_SECONDS=#{ENV.fetch("GITHUB_REQUEST_PAUSE_SECONDS", 0)}"
      puts "    GITHUB_BUILDER_PAUSE_SECONDS=#{ENV.fetch("GITHUB_BUILDER_PAUSE_SECONDS", 0)}"
      puts "    GITHUB_RATE_LIMIT_PAUSE_SECONDS=#{ENV.fetch("GITHUB_RATE_LIMIT_PAUSE_SECONDS", 60)}"
      puts "    GITHUB_RATE_LIMIT_RETRIES=#{ENV.fetch("GITHUB_RATE_LIMIT_RETRIES", 1)}"
      result[:results].each do |login, builder_result|
        puts(
          "  #{login}: strategy=#{builder_result[:strategy]} stored=#{builder_result[:stored]} " \
          "cache_rows=#{builder_result[:cache_rows] || 0} commits=#{builder_result[:total_cached_commits] || 0} " \
          "complete=#{builder_result[:complete] || false} elapsed=#{builder_result[:elapsed_seconds]}s"
        )
      end
    end

    desc "Mark builders at or above a cached commit-total cutoff as included in the roster. [CUTOFF=mitchellh] [RANGE_LIMIT=13]"
    task apply_builder_roster_cutoff: :environment do
      cutoff_login = ENV.fetch("CUTOFF", "mitchellh")
      range_limit = ENV.fetch("RANGE_LIMIT", Github::BuilderRosterCutoff::DEFAULT_RANGE_LIMIT).to_i
      result = Github::BuilderRosterCutoff.new(range_limit: range_limit).apply!(cutoff_login: cutoff_login)

      puts "AI Builder Multiple roster cutoff applied"
      puts "  cutoff login: #{result[:cutoff_login]}"
      puts "  cutoff rank: #{result[:cutoff_rank]}"
      puts "  cutoff total commits: #{result[:cutoff_total_commits]}"
      puts "  included builders: #{result[:included_count]}"
      puts "  excluded builders: #{result[:excluded_count]}"
      puts "  ranges: #{result[:range_count]} (#{result[:range_start_date]} to #{result[:range_end_date]})"
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

    desc "Import Ruby builders from Paul Miller's active GitHub users gist into Builder + Person. [MAX=] [ENRICH_PROFILES=true] [ACTIVE=true]"
    task import_paulmillr_ruby_builders: :environment do
      importer = Github::PaulMillrRubyBuildersImporter.new
      result = importer.import!(
        url: ENV.fetch("URL", Github::PaulMillrActiveUsersImporter::DEFAULT_URL),
        language: ENV.fetch("LANGUAGE", Github::PaulMillrRubyBuildersImporter::DEFAULT_LANGUAGE),
        active: ActiveModel::Type::Boolean.new.cast(ENV.fetch("ACTIVE", "true")),
        max: ENV["MAX"].presence,
        enrich_profiles: ActiveModel::Type::Boolean.new.cast(ENV.fetch("ENRICH_PROFILES", "true")),
        tracked_cohort: ENV.fetch("COHORT", "control_builder")
      )

      puts "Paul Miller Ruby builders import complete"
      puts "  source: #{result[:source_url]}"
      puts "  language: #{result[:language]}"
      puts "  rows seen: #{result[:seen]}"
      puts "  created: #{result[:created]}"
      puts "  updated: #{result[:updated]}"
      puts "  profiles enriched: #{result[:profiles_enriched]}"
      puts "  profile errors: #{result[:profile_errors]}"
    end
  end
end
