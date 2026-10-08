require "test_helper"

# [integration] The seed renames a user WITHOUT saving it.
#
# `before_save :set_name_parts` keeps `first_name`/`last_name` honest for every
# ordinary save. db/seeds/01_users.rb renames with `update_column`, so a rename
# does not re-point the slug the account answers on. `User.name_parts` derives the
# halves without a save, so that callback-free write still leaves the row consistent.
class RenamedNamePartsTest < ActiveSupport::TestCase
  TEAM = "team@mcritchie.studio"
  TURF = "turf@mcritchie.studio"
  MOVED = "team@turfmonster.media"
  WAS = "McRitchie Studio Team"
  NOW = "Team McRitchie"

  setup do
    User.where(email: [TEAM, TURF, MOVED]).delete_all
  end

  # A row shaped like one already sitting in a deployed database: created under
  # the roster that was in force THEN, so its halves are the ones that roster's
  # name derives. The callback puts them there; nothing here fakes them.
  def deployed(email, name:, role: "admin")
    user = User.create!(name: name, email: email)
    user.update_column(:role, role)
    user.reload
  end

  def run_seed = capture_io { load Rails.root.join("db/seeds/01_users.rb").to_s }

  def halves(row) = row.reload.slice("first_name", "last_name")

  # --- the premise ------------------------------------------------------------

  test "the old name and the new one derive opposite halves" do
    assert_equal({ first_name: "McRitchie", last_name: "Team" }, User.name_parts(WAS))
    assert_equal({ first_name: "Team", last_name: "McRitchie" }, User.name_parts(NOW))
  end

  # --- the seed's update_column -----------------------------------------------

  test "the seed's rename carries the derived halves with it" do
    team = deployed(TEAM, name: WAS)

    run_seed

    assert_equal NOW, team.reload.name
    assert_equal({ "first_name" => "Team", "last_name" => "McRitchie" }, halves(team),
                 "the seed's update_column left the halves derived from the OLD name")
  end

  test "the seed leaves the halves of a name someone chose alone" do
    team = deployed(TEAM, name: "Ops Desk")

    run_seed

    assert_equal "Ops Desk", team.reload.name
    assert_equal({ "first_name" => "Ops", "last_name" => "Desk" }, halves(team))
  end

  # A row the seed renamed and a row created fresh are indistinguishable.
  test "a seed-renamed row and a freshly seeded row agree on name parts" do
    deployed(TEAM, name: WAS)
    run_seed
    renamed = User.find_by!(email: TEAM).slice("name", "first_name", "last_name")

    User.where(email: TEAM).delete_all
    run_seed
    seeded = User.find_by!(email: TEAM).slice("name", "first_name", "last_name")

    assert_equal seeded, renamed
  end
end
