require "test_helper"

# [unit] The cast typeahead's ranking: exact > prefix > word prefix > contains,
# a name before an alias at each step, an artist before a bare person on a tie.
module Artists
  class SearchTest < ActiveSupport::TestCase
    setup do
      @migos = Artist.create!(slug: "migos", name: "Migos", kind: "group")
      @quavo = Artist.create!(slug: "quavo", name: "Quavo", kind: "person")
      ArtistAlias.create!(artist: @quavo, name: "Huncho")
      ArtistAlias.create!(artist: @quavo, name: "Quavo Stuntin")
      ArtistMembership.create!(member_artist_slug: "quavo", group_artist_slug: "migos")
      @yachty = Artist.create!(slug: "lil-yachty", name: "Lil Yachty", kind: "person")
      ArtistAlias.create!(artist: @yachty, name: "Lil Boat")
      Artist.create!(slug: "boat-house", name: "Boat House", kind: "group")
      Artist.create!(slug: "huncho-jack", name: "Huncho Jack", kind: "group")
    end

    def slugs(query) = Search.call(query).map(&:slug)

    test "an exact name beats a prefix, and a prefix beats a word prefix and a contains" do
      Artist.create!(slug: "quavoz", name: "Quavoz", kind: "person")
      Artist.create!(slug: "the-quavo-band", name: "The Quavo Band", kind: "group")
      Artist.create!(slug: "aquavox", name: "Aquavox", kind: "group")

      assert_equal %w[quavo quavoz the-quavo-band aquavox], slugs("quavo")
    end

    test "an alias finds its artist and says which alias matched" do
      result = Search.call("lil boat").first

      assert_equal ["artist", "lil-yachty", "Lil Yachty", "person"], [result.type, result.slug, result.name, result.kind]
      assert_equal "aka Lil Boat", result.hint
    end

    test "an exact alias outranks a name that merely starts with the query" do
      assert_equal %w[quavo huncho-jack], slugs("huncho")
    end

    test "a name prefix outranks an alias word prefix" do
      assert_equal %w[boat-house lil-yachty], slugs("boat")
    end

    test "an artist matched by name and alias appears once, at its best rank" do
      assert_equal ["quavo"], slugs("quavo stu").uniq
      assert_equal 1, slugs("quavo").count("quavo")
    end

    test "groups name their members and members name their groups" do
      assert_equal "members: Quavo", Search.call("migos").first.hint
      assert_match "member of Migos", Search.call("quavo").first.hint
    end

    test "people not yet artists are found, after an artist of equal rank" do
      Person.create!(slug: "migos-fan", first_name: "Migos", last_name: "Fan")
      linked = Person.create!(slug: "quavo-person", first_name: "Quavo", last_name: "Marshall")
      @quavo.update!(person_slug: linked.slug)

      results = Search.call("migos")
      assert_equal [%w[artist migos], %w[person migos-fan]], results.map { |r| [r.type, r.slug] }
      assert_equal "in People, not an artist yet", results.last.hint
      assert_not_includes slugs("quavo marshall"), "quavo-person"
    end

    test "matching ignores case and extra spaces, and LIKE wildcards are literal" do
      assert_equal ["lil-yachty"], slugs("  LIL   yachty ")
      assert_empty slugs("%")
      assert_empty slugs("_")
      assert_empty slugs("")
    end

    test "returns at most ten" do
      12.times { |i| Artist.create!(slug: "zed-#{i}", name: "Zed #{i}", kind: "person") }

      assert_equal 10, Search.call("zed").size
    end
  end
end
