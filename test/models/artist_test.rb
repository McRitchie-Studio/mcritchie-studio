require "test_helper"

class ArtistTest < ActiveSupport::TestCase
  test "sort name moves a leading The and defaults on save" do
    assert_equal "Roots, The", Artist.sort_name_for("The Roots")
    assert_equal "Theory of a Deadman", Artist.sort_name_for("Theory of a Deadman")
    artist = Artist.create!(slug: "the-roots", name: "The Roots", kind: "group")
    assert_equal "Roots, The", artist.sort_name
  end

  test "only an individual may link to a person, and kind is person or group" do
    group = Artist.new(slug: "migos", name: "Migos", kind: "group", person_slug: "someone")
    assert_not group.valid?
    assert_includes group.errors[:person_slug], "is only for individual artists"
    assert_not Artist.new(slug: "x", name: "X", kind: "band").valid?
  end

  test "a membership links member and group by slug" do
    group = Artist.create!(slug: "migos", name: "Migos", kind: "group")
    member = Artist.create!(slug: "quavo", name: "Quavo", kind: "person")
    ArtistMembership.create!(member: member, group: group, start_year: 2008, end_year: 2022)
    assert_equal [member], group.members.to_a
    assert_equal [group], member.groups.to_a
    assert_not ArtistMembership.new(member: member, group: member).valid?
  end
end
