require "test_helper"
require Rails.root.join("db/migrate/20260904190000_rename_turf_house_identity.rb").to_s
require Rails.root.join("db/migrate/20260905120000_sync_renamed_user_name_parts.rb").to_s

# [integration] The two writers that rename a user WITHOUT saving it.
#
# `before_save :set_name_parts` keeps `first_name`/`last_name` honest for every
# ordinary save. Two writers are not ordinary saves, on purpose:
#
#   · db/migrate/20260904190000_rename_turf_house_identity.rb — raw SQL, so
#     loading `User` cannot drag `assign_parked_identity` and Sluggable into a
#     migration that must still run years from now.
#   · db/seeds/01_users.rb — `update_column`, so a rename does not re-point the
#     slug the account answers on.
#
# Both reasons are good and neither is being taken away. What was missing is a way
# to derive the halves WITHOUT a save, so a callback-free write can still leave the
# row consistent. `User.name_parts` is that way; this file is the proof that both
# writers now use it and land on the same columns.
#
# MEASURED BEFORE THE FIX: a row created as "McRitchie Studio Team" carries
# first_name "McRitchie" / last_name "Team". `RenameTurfHouseIdentity#up` renames
# it to "Team McRitchie" and the halves do not move — so the row's own name reads
# backwards off its derived columns, and nothing self-heals it because
# `set_name_parts` is gated on `name_changed?`.
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
    user = User.create!(name: name, email: email, password: "password")
    user.update_column(:role, role)
    user.reload
  end

  def run_seed = capture_io { load Rails.root.join("db/seeds/01_users.rb").to_s }

  def migrate(direction) = capture_io { RenameTurfHouseIdentity.new.public_send(direction) }

  def repair(direction = :up) = capture_io { SyncRenamedUserNameParts.new.public_send(direction) }

  def halves(row) = row.reload.slice("first_name", "last_name")

  # A row exactly as a database that already ran the OLD rename holds it: renamed,
  # with the halves the name it no longer has derives. `update_columns` is the only
  # way to build it, because the fix means no live writer produces it any more.
  def fossil(email, was:, now:)
    row = deployed(email, name: was)
    row.update_columns(name: now)
    row.reload
  end

  # --- the premise: the fossil this task exists to stop making ---------------

  test "the old name and the new one derive opposite halves" do
    assert_equal({ first_name: "McRitchie", last_name: "Team" }, User.name_parts(WAS))
    assert_equal({ first_name: "Team", last_name: "McRitchie" }, User.name_parts(NOW))
  end

  # --- writer one: the migration's raw SQL ----------------------------------

  test "the migration's rename carries the derived halves with it" do
    team = deployed(TEAM, name: WAS)
    assert_equal({ "first_name" => "McRitchie", "last_name" => "Team" }, halves(team))

    migrate(:up)

    assert_equal NOW, team.reload.name
    assert_equal({ "first_name" => "Team", "last_name" => "McRitchie" }, halves(team),
                 "the raw-SQL rename left the halves derived from the OLD name")
  end

  test "rolling the migration back carries the halves back too" do
    team = deployed(TEAM, name: WAS)

    migrate(:up)
    migrate(:down)

    assert_equal WAS, team.reload.name
    assert_equal({ "first_name" => "McRitchie", "last_name" => "Team" }, halves(team),
                 "the rollback restored the name and left the halves on the new one")
  end

  test "the migration leaves the halves of a name someone chose alone" do
    team = deployed(TEAM, name: "Ops Desk")

    migrate(:up)

    assert_equal "Ops Desk", team.reload.name
    assert_equal({ "first_name" => "Ops", "last_name" => "Desk" }, halves(team))
  end

  # The address move is not a rename: it changes `email` and nothing the halves
  # are derived from, so they must survive it untouched.
  test "the migration's address move leaves the halves alone" do
    turf = deployed(TURF, name: "Turf Monster")

    migrate(:up)

    assert_equal MOVED, turf.reload.email
    assert_equal({ "first_name" => "Turf", "last_name" => "Monster" }, halves(turf))
  end

  # --- writer two: the seed's update_column ---------------------------------

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

  # --- the second acceptance criterion, constructed rather than argued -------

  # TWO ROWS, BUILT DOWN THE TWO REAL PATHS, COMPARED COLUMN FOR COLUMN.
  #
  # One row arrives at "Team McRitchie" by being renamed there from the old roster
  # name (what a database that has run the migration holds). The other arrives by
  # being created there from scratch (what a fresh `db:seed` holds). The task is
  # only finished when those two rows are indistinguishable, so this asserts that
  # directly instead of reasoning about which callbacks each path fires.
  test "a migrated row and a freshly seeded row agree on name parts" do
    deployed(TEAM, name: WAS)
    migrate(:up)
    migrated = User.find_by!(email: TEAM).slice("name", "first_name", "last_name")

    User.where(email: TEAM).delete_all
    run_seed
    seeded = User.find_by!(email: TEAM).slice("name", "first_name", "last_name")

    assert_equal seeded, migrated,
                 "a migrated row and a freshly seeded row disagree about the same account"
    assert_equal({ "name" => NOW, "first_name" => "Team", "last_name" => "McRitchie" }, seeded)
  end

  # The same comparison for the OTHER carrier of the same rename. The seed and the
  # migration are two copies of one move; a row that took the seed's path and a row
  # created fresh must also be indistinguishable.
  test "a seed-renamed row and a freshly seeded row agree on name parts" do
    deployed(TEAM, name: WAS)
    run_seed
    renamed = User.find_by!(email: TEAM).slice("name", "first_name", "last_name")

    User.where(email: TEAM).delete_all
    run_seed
    seeded = User.find_by!(email: TEAM).slice("name", "first_name", "last_name")

    assert_equal seeded, renamed
  end

  # --- the repair: rows the OLD rename already wrote -------------------------

  # Fixing the writer repairs nothing already written. A database that has run
  # RenameTurfHouseIdentity will never run it again, so its row stays fossilised.
  # Measured 2026-09-05: mcritchie-studio-qa held exactly this row.
  test "the repair resyncs a row the old rename left fossilised" do
    team = fossil(TEAM, was: WAS, now: NOW)
    assert_equal({ "first_name" => "McRitchie", "last_name" => "Team" }, halves(team))

    repair

    assert_equal NOW, team.reload.name
    assert_equal({ "first_name" => "Team", "last_name" => "McRitchie" }, halves(team))
  end

  # A row and a freshly seeded one, end to end through the path a DEPLOYED database
  # actually walks: renamed by the old writer, then repaired. The criterion is that
  # they cannot be told apart afterwards.
  test "a repaired row and a freshly seeded row agree on name parts" do
    fossil(TEAM, was: WAS, now: NOW)
    repair
    repaired = User.find_by!(email: TEAM).slice("name", "first_name", "last_name")

    User.where(email: TEAM).delete_all
    run_seed
    seeded = User.find_by!(email: TEAM).slice("name", "first_name", "last_name")

    assert_equal seeded, repaired
  end

  # THE GUARD THAT KEEPS THIS FROM BEING DATA LOSS. The engine's profile form and
  # its onboarding step write first_name/last_name DIRECTLY, so halves that
  # disagree with `name` are just as likely to be someone's edit as a fossil. Only
  # halves that are exactly what the OLD name derives get repaired.
  test "the repair leaves halves someone edited alone" do
    team = deployed(TEAM, name: NOW)
    team.update_columns(first_name: "Ops", last_name: "Desk")

    repair

    assert_equal({ "first_name" => "Ops", "last_name" => "Desk" }, halves(team),
                 "the repair overwrote halves the roster never derived")
  end

  test "the repair leaves a row that never took the rename alone" do
    team = deployed(TEAM, name: WAS)

    repair

    assert_equal WAS, team.reload.name
    assert_equal({ "first_name" => "McRitchie", "last_name" => "Team" }, halves(team))
  end

  test "the repair re-runs without touching a row it already agrees with" do
    team = fossil(TEAM, was: WAS, now: NOW)
    repair

    # NOW() inside a transaction is the TRANSACTION's clock, so a second run would
    # stamp an identical timestamp and this would pass either way. Park the row in
    # the past so an UPDATE that should not happen has somewhere visible to land.
    long_ago = 1.year.ago.change(usec: 0)
    team.update_column(:updated_at, long_ago)

    repair

    assert_equal long_ago, team.reload.updated_at, "a re-run rewrote a row it already agreed with"
  end

  test "the repair rolls back without touching anything" do
    team = fossil(TEAM, was: WAS, now: NOW)
    before = team.reload.attributes

    repair(:down)

    assert_equal before, team.reload.attributes
  end

  # --- the copies of one derivation, checked against each other --------------

  # Both migrations SPELL THE DERIVATION OUT rather than calling `User.name_parts`,
  # so each still runs against whatever `User` has become years from now. The cost
  # of that is three copies, and today is the only day they all exist.
  test "the migrations' inline derivation still agrees with the model's" do
    [WAS, NOW, "Turf Monster", "Cher", "  Ada   Lovelace  ", ""].each do |name|
      expected = User.name_parts(name)
      expected = [expected[:first_name], expected[:last_name]]

      assert_equal expected, SyncRenamedUserNameParts.new.send(:name_parts, name),
                   "the repair migration derives #{name.inspect} differently from User"
      assert_equal expected, RenameTurfHouseIdentity.new.send(:name_parts, name),
                   "the rename migration derives #{name.inspect} differently from User"
    end
  end

  test "the repair's spelled-out pair still agrees with the live roster" do
    assert_equal User::RETIRED_NAMES,
                 SyncRenamedUserNameParts::RENAMED.transform_values(&:first)

    SyncRenamedUserNameParts::RENAMED.each do |email, (_was, now)|
      assert_equal User.parked_identity_for(email: email).fetch(:name), now,
                   "the repair targets a name the roster no longer holds for #{email}"
    end

    assert_equal RenameTurfHouseIdentity::RENAMES, SyncRenamedUserNameParts::RENAMED,
                 "the repair and the rename it repairs disagree about which rename happened"
  end
end
