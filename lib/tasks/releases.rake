namespace :releases do
  desc "Refresh cached duration metrics for the most recent shipped releases"
  task refresh_duration_metrics: :environment do
    limit = ENV.fetch("LIMIT", "3").to_i
    limit = 3 if limit <= 0

    refreshed = Release::DurationCache.refresh_recent!(limit: limit)
    puts "release duration metrics refreshed: #{refreshed.keys.join(', ')}"
  end
end
