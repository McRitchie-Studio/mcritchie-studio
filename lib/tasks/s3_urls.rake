# Stored S3 URLs -> the new public base, for the S3 -> R2 cutover
# (docs/agents/system/asset-library-plan.md, Wave 2). Both are DRY RUNS unless
# APPLY=1, and both are idempotent. BUCKET narrows the match to another bucket
# (default mcritchie-studio-production). See S3UrlRewrite for what is covered.
#
#   bin/rails "s3_urls:rewrite[https://assets.mcritchie.studio]"            # counts per column
#   APPLY=1 bin/rails "s3_urls:rewrite[https://assets.mcritchie.studio]"    # writes
#   APPLY=1 bin/rails "s3_urls:rewrite_seed_json[https://assets.mcritchie.studio]"  # local, then commit
namespace :s3_urls do
  desc "Rewrite stored S3 URLs in the DB onto BASE (dry run unless APPLY=1)"
  task :rewrite, [:base] => :environment do |_task, args|
    S3UrlRewrite.new(base: args[:base], bucket: ENV.fetch("BUCKET", S3UrlRewrite::DEFAULT_BUCKET))
                .call(apply: ENV["APPLY"] == "1")
  end

  desc "Rewrite the S3 image URLs in db/seeds/data/pokemon.json onto BASE (dry run unless APPLY=1)"
  task :rewrite_seed_json, [:base] => :environment do |_task, args|
    rewrite = S3UrlRewrite.new(base: args[:base], bucket: ENV.fetch("BUCKET", S3UrlRewrite::DEFAULT_BUCKET))
    path = Rails.root.join("db/seeds/data/pokemon.json")
    rows = JSON.parse(path.read)
    changed = rewrite.rewrite_seed_rows(rows)
    if ENV["APPLY"] == "1"
      path.write("#{JSON.pretty_generate(rows)}\n")
      puts "APPLIED — #{changed} URL field(s) rewritten in #{path}"
    else
      puts "DRY RUN — #{changed} URL field(s) would be rewritten in #{path} (APPLY=1 to write)"
    end
  end
end
