# Music artists from Wikidata (CC0), in two steps so a deploy never calls out:
#
#   bin/rails artists:fetch_wikidata    → query Wikidata, rewrite the committed snapshot
#   bin/rails artists:import_wikidata   → load the snapshot (idempotent; the post-deploy step)
#
# SNAPSHOT=path overrides db/seeds/data/artists_wikidata.json for either task.
namespace :artists do
  desc "Fetch rappers and hip-hop/R&B/pop groups from Wikidata into the committed snapshot"
  task fetch_wikidata: :environment do
    path = ENV.fetch("SNAPSHOT", Artists::Wikidata::SnapshotImporter::DEFAULT_PATH.to_s)
    logger = ->(message) { puts message }
    fetcher = Artists::Wikidata::Fetcher.new(client: Artists::Wikidata::Client.new(logger: logger), logger: logger)
    snapshot = fetcher.call
    Artists::Wikidata::Fetcher.write(snapshot, path)
    puts "wrote #{path}: #{snapshot['artists'].size} artists, #{snapshot['memberships'].size} memberships, " \
         "#{(File.size(path) / 1024.0 / 1024).round(1)} MB"
  end

  desc "Load the Wikidata artist snapshot (upsert by wikidata_id; a re-run writes nothing)"
  task import_wikidata: :environment do
    path = ENV.fetch("SNAPSHOT", Artists::Wikidata::SnapshotImporter::DEFAULT_PATH.to_s)
    stats = Artists::Wikidata::SnapshotImporter.new(path).call
    puts "artists:import_wikidata #{stats.map { |k, v| "#{k}=#{v}" }.join(' ')}"
  end
end
