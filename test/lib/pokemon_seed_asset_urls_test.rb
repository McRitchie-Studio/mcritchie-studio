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

  def test_bucket_urls_are_on_the_assets_domain
    assets = urls.grep(%r{\Ahttps://assets\.mcritchie\.studio/pokemon/})
    refute_empty assets, "the seed file should serve its sprites from assets.mcritchie.studio"
  end
end
