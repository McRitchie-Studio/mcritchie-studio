require "test_helper"

# [unit] Name → artist: case-insensitive, exact name before alias, ambiguity
# reported rather than guessed.
class MusicVideosCreditResolverTest < ActiveSupport::TestCase
  setup do
    @migos = Artist.create!(slug: "migos", name: "Migos", kind: "group")
    @yachty = Artist.create!(slug: "lil-yachty", name: "Lil Yachty", kind: "person")
    ArtistAlias.create!(artist: @yachty, name: "Lil Boat")
  end

  def resolver = MusicVideos::CreditResolver.new

  test "exact name, any case" do
    assert_equal @migos, resolver.resolve("MIGOS").artist
  end

  test "alias when no name matches" do
    assert_equal @yachty, resolver.resolve("lil boat").artist
  end

  test "no match and ambiguity are reasons, not guesses" do
    assert_equal "no_match", resolver.resolve("Nobody").reason
    Artist.create!(slug: "migos-2", name: "Migos", kind: "person")
    result = resolver.resolve("Migos")
    assert_nil result.artist
    assert_equal "ambiguous", result.reason
  end

  test "known? feeds the parser" do
    assert resolver.known?("lil boat")
    assert_not resolver.known?("Nobody")
  end
end
