require "test_helper"
require Rails.root.join("db/migrate/20261018120000_rename_xan_display_name_to_ray").to_s

# [unit] The orchestrator's display name becomes Ray on a deployed row; the slug
# stays `xan`, and a name someone set by hand is left alone.
class RenameXanDisplayNameToRayTest < ActiveSupport::TestCase
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { RenameXanDisplayNameToRay.new.migrate(direction) }
  end

  test "renames the xan row from Xan to Ray and back, keeping the slug" do
    agents(:xan_agent).update_columns(name: "Xan")

    migrate(:up)
    assert_equal "Ray", agents(:xan_agent).reload.name
    assert_equal "xan", agents(:xan_agent).slug

    migrate(:down)
    assert_equal "Xan", agents(:xan_agent).reload.name
  end

  test "leaves a hand-set name alone" do
    agents(:xan_agent).update_columns(name: "Orchestrator")

    migrate(:up)
    assert_equal "Orchestrator", agents(:xan_agent).reload.name
  end

  test "the roster seed names the xan soul Ray" do
    row = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls").find { |s| s["slug"] == "xan" }
    assert_equal "Ray", row["name"]
  end
end
