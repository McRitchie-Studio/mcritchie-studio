require "test_helper"
require Rails.root.join("db/migrate/20260904190000_rename_turf_house_identity.rb").to_s

# THE ORPHAN ADMIN, from both ends.
#
# The Turf Monster identity changed ADDRESS, not just role. A role change reaches
# an existing row on its own — `assign_parked_identity` re-reads the roster by
# email on every save — but an address change cannot: the old row matches no
# parked identity afterwards, so nothing re-reads it and it keeps the role it was
# last saved with. That role was `admin`, on a Google group with zero members that
# is being deleted.
#
# Two mechanisms close it, because they reach different databases and neither
# reaches both: the migration is what runs in production (the release phase is
# `bin/rails db:migrate` alone, and `bin/dor-check` refuses a bare `db:seed` as a
# post-deploy command), and the seed is what a local, test or QA reset runs.
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
    User.create!(name: "Turf Monster", email: OLD, role: "admin", password: "password")
  end

  # A row shaped like one already sitting in production: created under whatever
  # roster was in force THEN, so the callback cannot be used to put it there.
  # `update_column` is the only way to make a row the current roster disagrees
  # with — which is precisely the state this migration exists to find.
  def deployed(email, role:, name: "Someone")
    user = User.create!(name: name, email: email, password: "password")
    user.update_column(:role, role)
    user
  end

  def run_seed = capture_io { load Rails.root.join("db/seeds/01_users.rb").to_s }

  def migrate(direction) = capture_io { RenameTurfHouseIdentity.new.public_send(direction) }

  # --- the two copies of the roster -----------------------------------------

  # The migration SPELLS THE ROSTER OUT instead of reading the constants, so it
  # still runs years from now against whatever `User` has become. The cost of that
  # is two copies, and the only day they can be checked against each other is
  # today. Without this the pair is written in three places with nothing tying
  # them together, which is how a later roster edit silently stops being deployed.
  test "the migration's spelled-out roster still agrees with the live one" do
    assert_equal User::RETIRED_EMAILS,
                 { RenameTurfHouseIdentity::OLD_EMAIL => RenameTurfHouseIdentity::NEW_EMAIL }

    assert_equal User::PARKED_IDENTITIES.to_h { |identity| [identity[:email], identity[:role]] },
                 RenameTurfHouseIdentity::ROLES

    assert_equal User::RETIRED_NAMES,
                 RenameTurfHouseIdentity::RENAMES.transform_values(&:first)

    RenameTurfHouseIdentity::RENAMES.each do |email, (_was, now)|
      assert_equal User.parked_identity_for(email: email).fetch(:name), now,
                   "the migration renames #{email} to a name the roster no longer holds"
    end
  end

  # --- the migration: the only one of the two that reaches production ---------

  test "the migration moves the deployed row and takes admin off it" do
    row = stale_admin

    migrate(:up)

    row.reload
    assert_equal NEW, row.email
    refute row.admin?, "the moved row kept admin — the leftover credential this closes"
    assert_equal 1, User.where(email: [OLD, NEW]).count, "the move duplicated the account"
  end

  test "the migration is idempotent and harmless with nothing to move" do
    stale_admin
    migrate(:up)

    assert_silent_move { migrate(:up) }
  end

  # BOTH ROWS EXIST. Someone signed in at the new address before the migration
  # ran. Merging two accounts is a judgment call — sessions and slugs on
  # both sides — so the operator gets to make it, but the stale row must NOT be
  # left holding admin while they decide, which is the whole risk.
  test "the migration demotes rather than collides when the new address is taken" do
    row = stale_admin
    other = User.create!(name: "Turf Monster", email: NEW, role: "admin", password: "password")

    migrate(:up)

    assert_equal OLD, row.reload.email, "the row should be left in place for a manual merge"
    refute row.admin?, "the stale row kept admin while waiting to be merged"
    assert_equal NEW, other.reload.email
  end

  test "the migration reverses" do
    row = stale_admin

    migrate(:up)
    migrate(:down)

    assert_equal OLD, row.reload.email
    assert row.admin?, "rolling back should restore the role that revision's roster gave it"
  end

  # --- the reconciler: the half a release actually performs ------------------

  # THE DEFECT THIS FILE WAS BOUNCED FOR. A demotion in PARKED_IDENTITIES reaches a
  # deployed row only when something SAVES that row, and a release saves nothing.
  # So "mason is a viewer now" was true of the roster and false of production, with
  # no step anywhere in between that would ever have closed the gap.
  test "the migration demotes a deployed row the roster no longer calls an admin" do
    mason = deployed(MASON, role: "admin", name: "Mason McRitchie")

    migrate(:up)

    assert_equal "viewer", mason.reload.role, "mason kept admin through the release that demoted him"
  end

  # THE CONTROL CASE, and why the callback cannot be trusted to converge: mack was
  # made a viewer in the roster on 2026-08-14 and was still an admin in production
  # twenty-one days later. Reconciling EVERY seat, not only the ones this task
  # edits, is what closes drift nobody is watching for.
  test "the migration closes drift the callback never reached" do
    mack = deployed(MACK, role: "admin", name: "Mack McRitchie")

    migrate(:up)

    assert_equal "viewer", mack.reload.role
  end

  test "the migration leaves a row no parked identity claims alone" do
    stranger = User.create!(name: "Stranger", email: "stranger@example.com", role: "admin", password: "password")

    migrate(:up)

    assert stranger.reload.admin?, "the reconciler reached past the roster it was handed"
  end

  test "the reconciler re-runs without touching a row it already agrees with" do
    mason = deployed(MASON, role: "admin", name: "Mason McRitchie")
    migrate(:up)

    # NOW() inside a transaction is the TRANSACTION's clock, so a second run would
    # stamp an identical timestamp and this would pass either way. Park the row in
    # the past so an UPDATE that should not happen has somewhere visible to land.
    long_ago = 1.year.ago.change(usec: 0)
    mason.update_column(:updated_at, long_ago)

    migrate(:up)

    assert_equal long_ago, mason.reload.updated_at, "a re-run rewrote a row it already agreed with"
  end

  test "rolling back restores the role the previous roster declared" do
    mason = deployed(MASON, role: "admin", name: "Mason McRitchie")
    mack = deployed(MACK, role: "admin", name: "Mack McRitchie")

    migrate(:up)
    migrate(:down)

    assert mason.reload.admin?, "the roster before this revision called mason an admin"
    assert_equal "viewer", mack.reload.role, "mack was a viewer in that roster too; only his row lagged"
  end

  # --- the display name the roster cannot change on its own ------------------

  # `assign_parked_identity` fills a BLANK name and never overwrites one, and the
  # seed enforces role but not name. So renaming a seat in the roster
  # renames the literal and no account at all, unless something finishes the job.
  test "the migration finishes the rename the roster only declared" do
    team = deployed(TEAM, role: "admin", name: "McRitchie Studio Team")

    migrate(:up)

    assert_equal "Team McRitchie", team.reload.name
  end

  test "the migration leaves a name someone chose alone" do
    team = deployed(TEAM, role: "admin", name: "Ops Desk")

    migrate(:up)

    assert_equal "Ops Desk", team.reload.name, "the rename overwrote a name the roster never put there"
  end

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

  # The seed and the migration must not DISAGREE about what a half-moved identity
  # is allowed to keep. Both leave the merge to the operator; neither leaves the
  # stale row holding admin while they decide.
  test "the seed demotes rather than collides when the new address is taken" do
    row = stale_admin
    User.create!(name: "Turf Monster", email: NEW, role: "viewer", password: "password")

    run_seed

    assert_equal OLD, row.reload.email, "the row should be left in place for a manual merge"
    refute row.admin?, "the seed left the stale row on admin where the migration demotes it"
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

  private

  def assert_silent_move
    before = User.where(email: [OLD, NEW]).map { |u| u.slice("id", "email", "role") }.sort_by { |h| h["id"] }
    yield
    after = User.where(email: [OLD, NEW]).map { |u| u.slice("id", "email", "role") }.sort_by { |h| h["id"] }
    assert_equal before, after, "a re-run changed rows it had already moved"
  end
end
