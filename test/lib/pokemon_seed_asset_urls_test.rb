# frozen_string_literal: true

# [unit] db/seeds/data/pokemon.json serves its images from the hub's R2 public
# domain, not the S3 bucket the hub moved off (asset-library Wave 2, cutover of
# 2026-09-30). A re-seed from a file still naming S3 would quietly point every
# mascot back at the store being retired, which only breaks once S3 is gone.

require "minitest/autorun"
require "json"

class PokemonSeedAssetUrlsTest < Minitest::Test
  SEED = File.expand_path("../../db/seeds/data/pokemon.json", __dir__)

  def urls
    JSON.parse(File.read(SEED)).flat_map { |row| row.values.grep(%r{\Ahttps?://}) }
  end

  def test_no_seed_url_names_an_s3_bucket
    s3 = urls.grep(/amazonaws\.com/)
    assert_empty s3, "#{s3.size} seed URL(s) still point at S3, e.g. #{s3.first}"
  end

  # The e2e stack seeds three mascots by hand (e2e/seed.rb) with the same image
  # paths; they must not keep the retired S3 host either.
  def test_the_e2e_seed_names_no_s3_bucket_url
    e2e = File.read(File.expand_path("../../e2e/seed.rb", __dir__))
    s3 = e2e.scan(%r{https://[^"\s]*amazonaws\.com[^"\s]*})
    assert_empty s3, "e2e/seed.rb still names S3: #{s3.first}"
    assert e2e.include?("https://assets.mcritchie.studio/pokemon/"), "e2e/seed.rb should build sprites on the assets domain"
  end

  # EVERY URL, not "at least one". Seed assets live in the production bucket and
  # every environment's seed data references them there; a slice re-fetched on a
  # machine whose storage is the dev bucket must not be able to commit dev URLs
  # beside the production ones and still pass.
  def test_every_seed_url_is_on_the_production_assets_domain
    refute_empty urls
    elsewhere = urls.grep_v(%r{\Ahttps://assets\.mcritchie\.studio/pokemon/})
    assert_empty elsewhere, "#{elsewhere.size} seed URL(s) are not on the production asset host, e.g. #{elsewhere.first}"
  end

  # The same rule for every seed file: nothing a seed commits may point at a
  # non-production bucket's public host. assets-dev.<domain> is where a local
  # or QA process serves its OWN uploads from, and a seed that names it is
  # naming objects production does not have.
  def test_no_seed_file_names_a_dev_bucket_host
    root = File.expand_path("../..", __dir__)
    files = Dir.glob(File.join(root, "db/seeds/**/*")).select { |f| File.file?(f) }
    files += [File.join(root, "db/seeds.rb"), File.join(root, "e2e/seed.rb")]
    assert_operator files.size, :>, 40, "the glob has to find the seed files to mean anything"
    hits = files.select { |f| File.read(f, encoding: "BINARY").match?(/assets-dev\.|-dev\.r2\.dev/) }
    assert_empty hits.map { |f| f.delete_prefix("#{root}/") }
  end
end
