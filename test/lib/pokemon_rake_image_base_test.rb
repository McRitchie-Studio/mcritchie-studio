require "test_helper"
require "rake"

# [unit] lib/tasks/pokemon.rake builds image URLs from the storage adapter
# (Studio::S3), not a hard-coded S3 base: the public base once one is set (R2),
# else the legacy path-style AWS URL for the bucket the upload writes to.
class PokemonRakeImageBaseTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("pokemon:fetch")
    @rake = Object.new
    @public_url = Studio.s3_public_url
    @endpoint = Studio.s3_endpoint
    Studio.s3_endpoint = nil
  end

  teardown do
    Studio.s3_public_url = @public_url
    Studio.s3_endpoint = @endpoint
    ENV.delete("POKEMON_S3_BUCKET")
  end

  test "with a public base configured, images live under it" do
    Studio.s3_public_url = "https://assets.mcritchie.studio/"
    assert_equal "https://assets.mcritchie.studio/pokemon", @rake.send(:pokemon_image_base)
  end

  test "on AWS, the path-style URL of the upload bucket (byte-identical to the old S3_BASE)" do
    Studio.s3_public_url = nil
    assert_equal "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon",
                 @rake.send(:pokemon_image_base)

    ENV["POKEMON_S3_BUCKET"] = "mcritchie-studio-dev"
    assert_equal "https://s3.us-east-2.amazonaws.com/mcritchie-studio-dev/pokemon",
                 @rake.send(:pokemon_image_base)
  end

  test "on an S3-compatible endpoint with no public base it fails closed" do
    Studio.s3_public_url = nil
    Studio.s3_endpoint = "https://acct.r2.cloudflarestorage.com"
    assert_raises(Studio::S3::NotConfigured) { @rake.send(:pokemon_image_base) }
  end

  test "S3_BASE is gone" do
    refute Object.const_defined?(:S3_BASE), "URLs come from the adapter now"
  end
end
