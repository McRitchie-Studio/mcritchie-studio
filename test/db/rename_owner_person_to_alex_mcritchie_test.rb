require "test_helper"
require Rails.root.join("db/migrate/20261025232000_rename_owner_person_to_alex_mcritchie.rb").to_s

# [unit] The owner's agent person reads "Alex McRitchie" on a deployed row, with
# its identities; another person named Alex, and a hand-set name, are untouched;
# and the move reverses.
class RenameOwnerPersonToAlexMcritchieTest < ActiveSupport::TestCase
  M = RenameOwnerPersonToAlexMcritchie

  def migrate(direction) = capture_io { M.new.public_send(direction) }

  setup do
    AgentPersonIdentity.where(platform: "discord", external_id: M::OWNER_DISCORD_ID).delete_all
    @owner = AgentPerson.create!(display_name: "Alex", role: "owner")
    @owner.identities.create!(platform: "discord", external_id: M::OWNER_DISCORD_ID, display_name: "Alex")
    @owner.identities.create!(platform: "email", external_id: "owner-mig@example.test", display_name: "Alex")
    @namesake = AgentPerson.create!(display_name: "Alex", role: "public")
    @namesake.identities.create!(platform: "discord", external_id: "42", display_name: "Alex")
  end

  test "the owner and his identities read Alex McRitchie, a namesake does not, and down reverses" do
    migrate(:up)

    assert_equal "Alex McRitchie", @owner.reload.display_name
    assert_equal ["Alex McRitchie"], @owner.identities.pluck(:display_name).uniq
    assert_equal "Alex", @namesake.reload.display_name, "a stranger named Alex is not the owner"
    assert_equal ["Alex"], @namesake.identities.pluck(:display_name)

    migrate(:down)
    assert_equal "Alex", @owner.reload.display_name
  end

  test "a name set by hand is kept" do
    @owner.update_columns(display_name: "The Boss")
    migrate(:up)
    assert_equal "The Boss", @owner.reload.display_name
  end

  test "a fresh seed names the owner Alex McRitchie" do
    assert_equal "Alex McRitchie", AgentPerson::OWNER[:name]
  end
end
