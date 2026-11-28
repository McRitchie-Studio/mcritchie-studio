require "test_helper"
require Rails.root.join("db/migrate/20261127190000_add_mcritchie_soul.rb").to_s

# [unit] AddMcritchieSoul gives a deployed database the McRitchie row the seed alone
# never reaches, leaves an existing row alone, and rolls back only a row nothing
# references.
class AddMcritchieSoulMigrationTest < ActiveSupport::TestCase
  M = AddMcritchieSoul

  setup { Agent.where(slug: M::SLUG).delete_all }

  def migrate(direction) = capture_io { M.new.public_send(direction) }

  def soul_record = YAML.safe_load_file(Rails.root.join("config/souls.yml")).fetch("souls").find { |s| s["slug"] == M::SLUG }

  test "[unit] up creates the mcritchie row from the roster's own fields; down removes it" do
    migrate(:up)
    row = Agent.find_by!(slug: M::SLUG)
    record = soul_record
    %w[name status agent_type title description avatar position].each do |field|
      assert_equal record.fetch(field), row.public_send(field), "#{field} drifted from config/souls.yml"
    end
    assert_equal record.fetch("emoji"), row.metadata["emoji"]
    assert_equal record.fetch("color"), row.metadata["color"]

    migrate(:down)
    refute Agent.exists?(slug: M::SLUG)
  end

  test "[unit] up leaves an existing mcritchie row alone" do
    Agent.create!(slug: M::SLUG, name: "McRitchie", avatar: "/agents/custom.webp")
    migrate(:up)
    assert_equal "/agents/custom.webp", Agent.find_by!(slug: M::SLUG).avatar
    assert_equal 1, Agent.where(slug: M::SLUG).count
  end

  test "[unit] down keeps a row that history hangs off" do
    migrate(:up)
    Activity.create!(agent_slug: M::SLUG, activity_type: "note", description: "McRitchie's first word")
    migrate(:down)
    assert Agent.exists?(slug: M::SLUG)
  end
end
