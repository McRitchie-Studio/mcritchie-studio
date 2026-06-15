require "test_helper"

class ArenaTest < ActiveSupport::TestCase
  test "slug is generated from name" do
    arena = Arena.create!(name: "Lumen Field")

    assert_equal "lumen-field", arena.slug
  end

  test "has home teams by home arena slug" do
    arena = arenas(:highmark_stadium)

    assert_includes arena.home_teams, teams(:buffalo_bills)
  end
end
