require "test_helper"

class AppTest < ActiveSupport::TestCase
  test "default resolves the McRitchie Studio app a new session adopts" do
    assert_equal "mcritchie-studio", App.default.slug
    assert_equal "#B57EDC", App.default.color, "MS reads lavender"
  end

  test "each app carries a distinct status-line color" do
    assert_equal "#22C55E", App.find_by!(slug: "turf-monster").color, "TM reads green"
    refute_equal App.find_by!(slug: "mcritchie-studio").color,
                 App.find_by!(slug: "turf-monster").color
  end

  test "requires a name and a unique slug" do
    assert_not App.new(slug: "x").valid?, "name is required"
    dup = App.new(name: "Dup", slug: "mcritchie-studio")
    assert_not dup.valid?, "slug must be unique"
  end

  test "Sluggable derives the slug from the name on save" do
    app = App.create!(name: "Chain Ops", slug: "placeholder", color: "#38BDF8")
    assert_equal "chain-ops", app.slug, "the slug is (re)derived from the parameterized name"
    assert_equal "chain-ops", app.to_param
  end
end
