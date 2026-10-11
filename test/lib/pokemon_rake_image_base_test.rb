require "test_helper"
require "rake"

# [unit] lib/tasks/pokemon.rake writes the committed seed JSON's image URLs on
# the PRODUCTION asset host, whatever storage the running process is on, and
# its upload tasks refuse the production bucket from a non-production process.
#
# The base used to come from the storage adapter (Studio::S3.url). That is the
# right answer for an object the process just wrote and the wrong one for a
# seed file: local development runs with the DEV bucket's public URL, so a
# local `pokemon:fetch` would have committed assets-dev URLs for production to
# seed from.
class PokemonRakeImageBaseTest < ActiveSupport::TestCase
  PRODUCTION_BASE = "https://assets.mcritchie.studio/pokemon".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("pokemon:fetch")
    @rake = Object.new
    @public_url = Studio.s3_public_url
    @endpoint = Studio.s3_endpoint
  end

  teardown do
    Studio.s3_public_url = @public_url
    Studio.s3_endpoint = @endpoint
    ENV.delete("POKEMON_S3_BUCKET")
  end

  # The AWS branch (a path-style amazonaws.com URL when no endpoint was set) is
  # gone with AWS (hub-storage-runs-r2-only). Under any configuration the seed
  # base is the production asset host.
  test "a configured public URL yields the production asset host, never amazonaws" do
    Studio.s3_public_url = "https://assets.mcritchie.studio"
    ENV["POKEMON_S3_BUCKET"] = "mcritchie-studio-dev"
    assert_equal "https://assets.mcritchie.studio/pokemon", @rake.send(:pokemon_image_base)
    refute_match(/amazonaws/, Rails.root.join("lib/tasks/pokemon.rake").read)
  end

  # THE REGRESSION: the local-development configuration, exactly.
  test "on the dev bucket's public URL, seed URLs still name production" do
    Studio.s3_endpoint = "https://acct.r2.cloudflarestorage.com"
    Studio.s3_public_url = "https://assets-dev.mcritchie.studio"
    assert_equal PRODUCTION_BASE, @rake.send(:pokemon_image_base)
  end

  test "with no storage configured at all, seed URLs still name production" do
    Studio.s3_endpoint = nil
    Studio.s3_public_url = nil
    assert_equal PRODUCTION_BASE, @rake.send(:pokemon_image_base)
  end

  test "the upload bucket override does not move the seed URLs" do
    ENV["POKEMON_S3_BUCKET"] = "mcritchie-studio-dev"
    assert_equal PRODUCTION_BASE, @rake.send(:pokemon_image_base)
  end

  test "no AWS host is built any more" do
    source = File.read(Rails.root.join("lib/tasks/pokemon.rake"))
    code = source.lines.reject { |line| line.lstrip.start_with?("#") }.join
    refute_match(/amazonaws\.com/, code)
    refute Object.const_defined?(:S3_BASE), "S3_BASE stays gone"
  end

  # --- the upload guard ------------------------------------------------------

  test "a non-production process is refused the production bucket, before any upload" do
    refute Studio::S3.production_environment?, "the test env is the non-production case"
    assert_equal "mcritchie-studio-production", @rake.send(:pokemon_bucket), "the default the guard has to catch"

    _out, err = capture_io do
      assert_raises(SystemExit) { @rake.send(:pokemon_upload_bucket!) }
    end
    assert_match(/refusing to upload to mcritchie-studio-production/, err)
    assert_match(/NOTHING was uploaded/, err)
    assert_match(/POKEMON_S3_BUCKET=mcritchie-studio-dev/, err, "name the bucket a rehearsal may write")
  end

  test "a non-production process may write the dev bucket" do
    ENV["POKEMON_S3_BUCKET"] = "mcritchie-studio-dev"
    assert_equal "mcritchie-studio-dev", @rake.send(:pokemon_upload_bucket!)
  end

  test "production writes the production bucket" do
    Studio::S3.stub(:production_environment?, true) do
      assert_equal "mcritchie-studio-production", @rake.send(:pokemon_upload_bucket!)
    end
  end

  # Both upload tasks go through the guard: a task that reads pokemon_bucket
  # directly hands the client the production name unguarded.
  test "both upload tasks take their bucket from the guard" do
    source = File.read(Rails.root.join("lib/tasks/pokemon.rake"))
    assert_equal 2, source.scan(/^\s+bucket = pokemon_upload_bucket!$/).size
    assert_equal 1, source.scan(/^\s+bucket = pokemon_bucket$/).size, "only the guard itself reads the raw name"
  end
end
