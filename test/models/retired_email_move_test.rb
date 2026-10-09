require "test_helper"

# THE ORPHAN ADMIN, from both ends.
#
# The Turf Monster identity changed ADDRESS, not just role. A role change reaches
# an existing row on its own — `assign_parked_identity` re-reads the roster by
# email on every save — but an address change cannot: the old row matches no
# parked identity afterwards, so nothing re-reads it and it keeps the role it was
# last saved with. That role was `admin`, on a Google group with zero members that
# is being deleted.
#
# The seed closes it on a local, test or QA reset: it moves the row, demotes it,
# and finishes the rename the roster only declared.
class RetiredEmailMoveTest < ActiveSupport::TestCase
  OLD = "turf@mcritchie.studio"
  NEW = "team@turfmonster.media"
  MASON = "mason@mcritchie.studio"
  MACK = "mack@mcritchie.studio"
  TEAM = "team@mcritchie.studio"

  setup do
    User.where(email: [OLD, NEW, MASON, MACK, TEAM]).delete_all
  end

  def stale_admin
    User.create!(name: "Turf Monster", email: OLD, role: "admin")
  end

  # A row shaped like one already sitting in production: created under whatever
  # roster was in force THEN, so the callback cannot be used to put it there.
  # `update_column` is the only way to make a row the current roster disagrees
  # with.
  def deployed(email, role:, name: "Someone")
    user = User.create!(name: name, email: email)
    user.update_column(:role, role)
    user
  end

  def run_seed = capture_io { load Rails.root.join("db/seeds/01_users.rb").to_s }


  # --- the seed: local, test, and a QA reset ---------------------------------

  test "the seed moves an existing row instead of creating a second account" do
    row = stale_admin

    run_seed

    assert_equal NEW, row.reload.email
    assert_nil User.find_by(email: OLD)
    assert_equal 1, User.where(email: NEW).count, "the seed created a second Turf account"
  end

  # The role arrives via the roster on the next save, NOT from the rename itself —
  # so assert it lands, rather than assuming the update_column did it.
  test "the seeded move lands the roster's role" do
    stale_admin

    run_seed

    refute User.find_by(email: NEW).admin?
  end

  # A half-moved identity: the seed leaves the merge to the operator and never
  # leaves the stale row holding admin while they decide.
  test "the seed demotes rather than collides when the new address is taken" do
    row = stale_admin
    User.create!(name: "Turf Monster", email: NEW, role: "viewer")

    run_seed

    assert_equal OLD, row.reload.email, "the row should be left in place for a manual merge"
    refute row.admin?, "the seed left the stale row on admin"
    assert_equal 1, User.where(email: NEW).count
  end

  test "the seed finishes the rename the roster only declared" do
    team = deployed(TEAM, role: "admin", name: "McRitchie Studio Team")

    run_seed

    assert_equal "Team McRitchie", team.reload.name
  end

  test "the seed leaves a name someone chose alone" do
    team = deployed(TEAM, role: "admin", name: "Ops Desk")

    run_seed

    assert_equal "Ops Desk", team.reload.name, "the rename overwrote a name the roster never put there"
  end

end
