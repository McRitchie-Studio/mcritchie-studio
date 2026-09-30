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

  def test_bucket_urls_are_on_the_assets_domain
    assets = urls.grep(%r{\Ahttps://assets\.mcritchie\.studio/pokemon/})
    refute_empty assets, "the seed file should serve its sprites from assets.mcritchie.studio"
  end
end
