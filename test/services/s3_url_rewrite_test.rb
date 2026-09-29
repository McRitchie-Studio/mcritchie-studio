require "test_helper"

# [unit] S3UrlRewrite.rewrite_url: our bucket's URLs (both S3 styles) map onto the
# new public base with the key intact; anything else comes back nil (untouched).
class S3UrlRewriteTest < ActiveSupport::TestCase
  BASE = "https://assets.mcritchie.studio".freeze

  def rewrite(url, base: BASE, bucket: S3UrlRewrite::DEFAULT_BUCKET)
    S3UrlRewrite.rewrite_url(url, base: base, bucket: bucket)
  end

  test "path-style URL maps onto the base, key intact" do
    assert_equal "#{BASE}/pokemon/25-pikachu-sprite.png",
                 rewrite("https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon/25-pikachu-sprite.png")
  end

  test "virtual-hosted URL maps onto the base, key and query intact" do
    assert_equal "#{BASE}/character-sheets/a%20b.png?v=2",
                 rewrite("https://mcritchie-studio-production.s3.us-east-2.amazonaws.com/character-sheets/a%20b.png?v=2")
  end

  test "legacy regionless and dashed-region hosts match too" do
    assert_equal "#{BASE}/x.png", rewrite("https://s3.amazonaws.com/mcritchie-studio-production/x.png")
    assert_equal "#{BASE}/x.png", rewrite("https://mcritchie-studio-production.s3.amazonaws.com/x.png")
    assert_equal "#{BASE}/x.png", rewrite("https://s3-us-east-2.amazonaws.com/mcritchie-studio-production/x.png")
    assert_equal "#{BASE}/x.png", rewrite("http://mcritchie-studio-production.s3.us-east-2.amazonaws.com/x.png")
  end

  test "a trailing slash on the base does not double up" do
    assert_equal "#{BASE}/x.png",
                 rewrite("https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/x.png", base: "#{BASE}/")
  end

  test "another bucket, an external host, and a URL that merely embeds ours stay untouched" do
    assert_nil rewrite("https://s3.us-east-2.amazonaws.com/mcritchie-studio-dev/pokemon/x.png")
    assert_nil rewrite("https://mcritchie-studio-production-old.s3.us-east-2.amazonaws.com/x.png")
    assert_nil rewrite("https://s3.us-east-2.amazonaws.com/mcritchie-studio-productionx/x.png")
    assert_nil rewrite("https://a.espncdn.com/i/headshots/nfl/players/full/1.png")
    assert_nil rewrite("https://ca-times.brightspotcdn.com/dims4/x?url=https%3A%2F%2Fmcritchie-studio-production.s3.us-east-2.amazonaws.com%2Fa.png")
    assert_nil rewrite("#{BASE}/pokemon/x.png"), "already rewritten: a re-run is a no-op"
    assert_nil rewrite(nil)
    assert_nil rewrite("")
  end

  test "the bucket is a parameter" do
    assert_equal "#{BASE}/x.png",
                 rewrite("https://s3.us-east-2.amazonaws.com/mcritchie-studio-dev/x.png", bucket: "mcritchie-studio-dev")
  end

  test "a base that is not an absolute https URL is refused" do
    ["", "assets.mcritchie.studio", "http://assets.mcritchie.studio", "https://", nil].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { S3UrlRewrite.new(base: bad) }
    end
  end

  test "rewrite_seed_rows rewrites every image field of the pokemon seed rows" do
    rows = [{ "slug" => "pikachu", "name" => "Pikachu",
              "sprite_url" => "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon/25-pikachu-sprite.png",
              "shiny_female_sprite_url" => "https://s3.us-east-2.amazonaws.com/mcritchie-studio-production/pokemon/25-f.png",
              "avatar_url" => "https://raw.githubusercontent.com/x.png", "female_sprite_url" => nil }]
    rewrite = S3UrlRewrite.new(base: BASE)

    assert_equal 2, rewrite.rewrite_seed_rows(rows)
    assert_equal "#{BASE}/pokemon/25-pikachu-sprite.png", rows[0]["sprite_url"]
    assert_equal "#{BASE}/pokemon/25-f.png", rows[0]["shiny_female_sprite_url"]
    assert_equal "https://raw.githubusercontent.com/x.png", rows[0]["avatar_url"]
    assert_nil rows[0]["female_sprite_url"]
    assert_equal 0, rewrite.rewrite_seed_rows(rows), "a re-run is a no-op"
  end

  test "the pokemon columns it covers are the ones the rake writes and the table has" do
    assert_equal S3UrlRewrite::POKEMON_IMAGE_COLUMNS.sort, Pokemon.column_names.grep(/_url\z/).sort
  end
end
