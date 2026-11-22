require "test_helper"

# [component] alex-wears-mad-lad-4485 follow-up: the landing logo grid's Alex tile wears
# Mad Lads #4485 like every other Alex portrait, at the grid's 160px square.
class LogoGridAlexTileTest < ActiveSupport::TestCase
  TILE = Rails.root.join("app/assets/images/logo_grid/agent-alex.webp")
  RETIRED_SHA256 = "105c63b964a58dcd93558312d5dc7218fc6678020347e7430282b5f3e623fc0e".freeze

  test "[component] the grid still lists the Alex tile" do
    assert_includes LogoGridHelper::LOGO_GRID_TILES.map(&:first), "agent-alex"
  end

  test "[component] the Alex tile is a 160x160 webp and not the retired portrait" do
    bytes = TILE.binread
    assert_equal "RIFF", bytes[0, 4]
    assert_equal "WEBP", bytes[8, 4]
    refute_equal RETIRED_SHA256, Digest::SHA256.hexdigest(bytes), "the retired Alex face came back"
    assert_equal [160, 160], webp_size(bytes)
  end

  private

  # VP8 (lossy) keeps width/height as 14-bit little-endian fields at bytes 26..29.
  def webp_size(bytes)
    assert_equal "VP8 ", bytes[12, 4], "expected a lossy VP8 webp"
    bytes[26, 4].unpack("vv").map { |v| v & 0x3fff }
  end
end
