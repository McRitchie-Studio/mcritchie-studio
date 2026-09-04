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

  setup do
    User.where(email: [OLD, NEW]).delete_all
  end

  def stale_admin
    User.create!(name: "Turf Monster", email: OLD, role: "admin", password: "password")
  end

  def run_seed = capture_io { load Rails.root.join("db/seeds/01_users.rb").to_s }

  def migrate(direction) = capture_io { RenameTurfHouseIdentity.new.public_send(direction) }

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
  # ran. Merging two accounts is a judgment call — wallets, sessions and slugs on
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

  test "the seed leaves both rows alone when the new address is already taken" do
    row = stale_admin
    User.create!(name: "Turf Monster", email: NEW, role: "viewer", password: "password")

    run_seed

    assert_equal OLD, row.reload.email
    assert_equal 1, User.where(email: NEW).count
  end

  private

  def assert_silent_move
    before = User.where(email: [OLD, NEW]).map { |u| u.slice("id", "email", "role") }.sort_by { |h| h["id"] }
    yield
    after = User.where(email: [OLD, NEW]).map { |u| u.slice("id", "email", "role") }.sort_by { |h| h["id"] }
    assert_equal before, after, "a re-run changed rows it had already moved"
  end
end
