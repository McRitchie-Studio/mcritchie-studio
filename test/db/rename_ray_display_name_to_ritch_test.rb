require "test_helper"
require Rails.root.join("db/migrate/20261020210000_rename_ray_display_name_to_ritch").to_s

# [unit] The orchestrator's display name becomes Ritch on a deployed row; the
# slug stays `ray`, and a name someone set by hand is left alone.
class RenameRayDisplayNameToRitchTest < ActiveSupport::TestCase
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { RenameRayDisplayNameToRitch.new.migrate(direction) }
  end

  setup { @seat = agents(:ray_agent) }

  test "renames the ray row from Ray to Ritch and back, keeping the slug" do
    @seat.update_columns(name: "Ray")

    migrate(:up)
    assert_equal "Ritch", @seat.reload.name
    assert_equal "ray", @seat.slug

    migrate(:down)
    assert_equal "Ray", @seat.reload.name
  end

  test "leaves a hand-set name alone" do
    @seat.update_columns(name: "Orchestrator")

    migrate(:up)
    assert_equal "Orchestrator", @seat.reload.name
  end

  test "the roster seed names the ray soul Ritch, slug unchanged" do
    row = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls").find { |s| s["slug"] == "ray" }
    assert_equal "Ritch", row["name"]
  end
end
