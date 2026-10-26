require "test_helper"
require Rails.root.join("db/migrate/20261020210000_rename_ray_display_name_to_ritch").to_s

# [unit] The orchestrator's display name becomes Ritch on a deployed row; the
# slug stays `ray`, and a name someone set by hand is left alone. The fixture seat
# is slugged `alex` now (RenameRaySoulToAlex), so each test first puts it back the
# way a database between the two migrations holds it.
class RenameRayDisplayNameToRitchTest < ActiveSupport::TestCase
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { RenameRayDisplayNameToRitch.new.migrate(direction) }
  end

  setup { @seat = agents(:alex_agent) }

  test "renames the ray row from Ray to Ritch and back, keeping the slug" do
    @seat.update_columns(slug: "ray", name: "Ray")

    migrate(:up)
    assert_equal "Ritch", @seat.reload.name
    assert_equal "ray", @seat.slug

    migrate(:down)
    assert_equal "Ray", @seat.reload.name
  end

  test "leaves a hand-set name alone" do
    @seat.update_columns(slug: "ray", name: "Orchestrator")

    migrate(:up)
    assert_equal "Orchestrator", @seat.reload.name
  end

  test "the roster seed has moved on: the seat is alex, named Alex (RenameRaySoulToAlex)" do
    souls = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls")
    assert_nil souls.find { |s| s["slug"] == "ray" }
    assert_equal "Alex", souls.find { |s| s["slug"] == "alex" }["name"]
  end
end
