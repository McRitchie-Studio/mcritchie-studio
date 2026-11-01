# Music artists from Wikidata (CC0), in two steps so a deploy never calls out:
#
#   bin/rails artists:fetch_wikidata SNAPSHOT=path → query Wikidata, write a snapshot file
#   bin/rails seed_data:publish FILE=path NAME=artists_wikidata.json → upload it (production only)
#   bin/rails artists:import_wikidata              → load the R2 snapshot (idempotent; the post-deploy step)
#
# A deploy calls out only to our own R2. SNAPSHOT=path makes the import read a local file instead.
namespace :artists do
  desc "Fetch rappers and hip-hop/R&B/pop groups from Wikidata into a snapshot file. SNAPSHOT=path"
  task fetch_wikidata: :environment do
    path = ENV.fetch("SNAPSHOT") { abort "SNAPSHOT= is required" }
    logger = ->(message) { puts message }
    fetcher = Artists::Wikidata::Fetcher.new(client: Artists::Wikidata::Client.new(logger: logger), logger: logger)
    snapshot = fetcher.call
    Artists::Wikidata::Fetcher.write(snapshot, path)
    puts "wrote #{path}: #{snapshot['artists'].size} artists, #{snapshot['memberships'].size} memberships, " \
         "#{(File.size(path) / 1024.0 / 1024).round(1)} MB"
  end

  desc "Load the Wikidata artist snapshot (upsert by wikidata_id; a re-run writes nothing)"
  task import_wikidata: :environment do
    stats = Artists::Wikidata::SnapshotImporter.new(ENV["SNAPSHOT"]).call
    puts "artists:import_wikidata #{stats.map { |k, v| "#{k}=#{v}" }.join(' ')}"
  end
end
