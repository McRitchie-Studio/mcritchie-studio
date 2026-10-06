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

  test "a set slug stands when the name does not spell it" do
    app = App.create!(name: "10&5 Hospitality", slug: "10and5", color: "#0D9488")
    assert_equal "10and5", app.reload.slug, "the repo slug from config/apps.yml is the identity"
    app.update!(name: "Ten and Five")
    assert_equal "10and5", app.reload.slug, "a rename does not move the slug"
  end
end
