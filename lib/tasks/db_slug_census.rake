namespace :db do
  desc "Read-only census of every *_slug column: its target table and its orphan rows (SAMPLES=n, default 5)"
  task slug_census: :environment do
    rows = SlugCensus.new(sample_limit: Integer(ENV.fetch("SAMPLES", SlugCensus::SAMPLE_LIMIT))).run
    resolved = rows.select(&:resolved?)
    puts SlugCensus.to_markdown(rows)
    puts
    puts "columns: #{rows.size} · resolved: #{resolved.size} · unresolved: #{rows.size - resolved.size} · " \
         "clean: #{resolved.count { |r| r.orphans.zero? }} · with orphans: #{resolved.count { |r| r.orphans.positive? }} · " \
         "orphan rows: #{resolved.sum(&:orphans)}"
  end
end
