require "test_helper"

class Artists::Wikidata::SnapshotImporterTest < ActiveSupport::TestCase
  SNAPSHOT = Rails.root.join("test/fixtures/files/artists_wikidata_snapshot.json")

  def import = Artists::Wikidata::SnapshotImporter.new(SNAPSHOT).call

  test "imports artists, aliases and memberships and links members to groups" do
    stats = import

    assert_equal 8, Artist.count
    migos = Artist.find_by!(wikidata_id: "Q15777045")
    assert_equal "migos", migos.slug
    assert migos.group?
    assert_equal %w[Offset Quavo Takeoff], migos.members.order(:name).pluck(:name)
    assert_equal [[2008, 2022]], migos.member_memberships.distinct.pluck(:start_year, :end_year)
    assert_equal ["Migos"], Artist.find_by!(name: "Quavo").groups.pluck(:name)

    jay = Artist.find_by!(wikidata_id: "Q62766")
    assert_equal ["jay-z", "person", "21742", "3nFkdlSjzX9mRTtwJOzDYB"], [jay.slug, jay.kind, jay.discogs_id, jay.spotify_id]
    assert_nil jay.person_slug, "the seed never links people"
    assert_equal ["Hova", "Shawn Corey Carter"], jay.aliases.order(:name).pluck(:name)

    assert_equal %w[nirvana nirvana-q200], Artist.where(name: "Nirvana").order(:wikidata_id).pluck(:slug),
                 "a duplicate name takes the lower id bare and the other gets its id"
    assert_equal "Roots, The", Artist.find_by!(name: "The Roots").sort_name

    assert_equal 3, ArtistMembership.count, "a membership naming an unknown artist is skipped"
    assert_equal({ artists: 8, aliases: 2, memberships: 3, skipped_memberships: 1 }, stats)
  end

  test "re-running changes nothing" do
    import
    before = [Artist, ArtistAlias, ArtistMembership].map { |m| m.order(:id).pluck(:id, :updated_at) }

    travel 1.day do
      stats = import
      assert_equal({ artists: 0, aliases: 0, memberships: 0, skipped_memberships: 1 }, stats)
    end

    after = [Artist, ArtistAlias, ArtistMembership].map { |m| m.order(:id).pluck(:id, :updated_at) }
    assert_equal before, after
  end

  test "a changed source updates in place and keeps the slug an operator may rely on" do
    import
    jay = Artist.find_by!(wikidata_id: "Q62766")
    Person.find_or_create_by!(first_name: "Shawn", last_name: "Carter") # artists.person_slug carries a foreign key
    jay.update!(person_slug: "shawn-carter")

    data = JSON.parse(File.read(SNAPSHOT))
    data["artists"].find { |a| a["wikidata_id"] == "Q62766" }.merge!("name" => "JAY-Z", "spotify_id" => "new")
    data["memberships"].first["end_year"] = 2021
    stats = Artists::Wikidata::SnapshotImporter.new(data).call

    jay.reload
    assert_equal ["jay-z", "JAY-Z", "new", "shawn-carter"], [jay.slug, jay.name, jay.spotify_id, jay.person_slug]
    assert_equal 2021, ArtistMembership.find_by!(member_artist_slug: "quavo").end_year
    assert_equal 1, stats[:artists]
    assert_equal 1, stats[:memberships]
  end
end
