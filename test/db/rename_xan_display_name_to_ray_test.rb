require "test_helper"
require Rails.root.join("db/migrate/20261018120000_rename_xan_display_name_to_ray").to_s

# [unit] The orchestrator's display name becomes Ray on a deployed row; the slug
# stays `xan` (RenameXanSoulToRay moves it next), and a name someone set by hand
# is left alone. The fixture seat is slugged `ray` now, so each test first puts
# it back the way a database between the two migrations holds it.
class RenameXanDisplayNameToRayTest < ActiveSupport::TestCase
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { RenameXanDisplayNameToRay.new.migrate(direction) }
  end

  setup { @seat = agents(:ray_agent) }

  test "renames the xan row from Xan to Ray and back, keeping the slug" do
    @seat.update_columns(slug: "xan", name: "Xan")

    migrate(:up)
    assert_equal "Ray", @seat.reload.name
    assert_equal "xan", @seat.slug

    migrate(:down)
    assert_equal "Xan", @seat.reload.name
  end

  test "leaves a hand-set name alone" do
    @seat.update_columns(slug: "xan", name: "Orchestrator")

    migrate(:up)
    assert_equal "Orchestrator", @seat.reload.name
  end

  test "the roster seed names the ray soul Ray" do
    row = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls").find { |s| s["slug"] == "ray" }
    assert_equal "Ray", row["name"]
  end
end
