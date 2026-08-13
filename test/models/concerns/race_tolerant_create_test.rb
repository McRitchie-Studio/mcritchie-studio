# frozen_string_literal: true

require "test_helper"

# RaceTolerantCreate swallows ONE failure — the uniqueness collision of a create
# race — and must let every other validation failure through untouched.
#
# That narrowness is the whole risk in the concern. The tempting fix for the race
# was `rescue ActiveRecord::RecordInvalid` with no further check, which would also
# eat a blank key, a bad `inclusion:`, and any validation added later, then hand
# the caller a row it never asked for. So these tests lean hardest on the failures
# that must STILL raise; they are the ones that catch the lazy fix.
#
# Exercised through the four real lease models rather than a fabricated AR class,
# because their validation sets are the ones the guard actually meets in
# production — including a scoped uniqueness (ReleaseConductorClaim) and an
# `inclusion:` on the very attribute being looked up.
class RaceTolerantCreateTest < ActiveSupport::TestCase
  LEASE_MODELS = [MigrationLaneClaim, DevopsShift, TaskReviewClaim, ReleaseConductorClaim].freeze

  # ── THE CONTRACT IS SHARED ────────────────────────────────────────────────

  test "[unit] every lease model with a create race uses the shared tolerant create" do
    LEASE_MODELS.each do |model|
      assert_includes model.ancestors, RaceTolerantCreate,
                      "#{model} runs the same create race and must not hand-roll its own rescue"
    end
  end

  # ── WHAT IT SWALLOWS ──────────────────────────────────────────────────────

  test "[unit] a uniqueness collision returns the row that already exists" do
    existing = MigrationLaneClaim.create!(lane: "backend_migration", claimed_session: "winner")
    # Exactly what a losing racer meets: the validator reports :taken because the
    # rival's row is already committed.
    found = MigrationLaneClaim.find_or_create_tolerating_race!(lane: "backend_migration")

    assert_equal existing.id, found.id, "the loser must be handed the winner's row"
    assert_equal 1, MigrationLaneClaim.where(lane: "backend_migration").count
  end

  test "[unit] a SCOPED uniqueness collision returns the existing row" do
    existing = ReleaseConductorClaim.create!(release_slug: "rel-2026-08-13", role: "assembler")
    found = ReleaseConductorClaim.find_or_create_tolerating_race!(release_slug: "rel-2026-08-13",
                                                                  role: "assembler")

    assert_equal existing.id, found.id
    # The scope is load-bearing: the same role under a DIFFERENT release is not a
    # collision at all and must create its own row.
    other = ReleaseConductorClaim.find_or_create_tolerating_race!(release_slug: "rel-2026-08-14",
                                                                  role: "assembler")
    refute_equal existing.id, other.id, "a different release is a different lease"
  end

  # ── WHAT IT MUST NOT SWALLOW (the mutation guards) ────────────────────────

  test "[unit] a blank key still raises — same attribute, different error" do
    error = assert_raises(ActiveRecord::RecordInvalid) do
      MigrationLaneClaim.find_or_create_tolerating_race!(lane: nil)
    end
    assert_equal [:blank], error.record.errors.details[:lane].map { |d| d[:error] }
  end

  test "[unit] an inclusion failure still raises — the attribute IS looked up" do
    # The sharpest case for the guard: `role` is one of the lookup keys, so an
    # attribute-only check would swallow this. Only the ERROR TYPE separates it
    # from the race.
    error = assert_raises(ActiveRecord::RecordInvalid) do
      ReleaseConductorClaim.find_or_create_tolerating_race!(release_slug: "rel-1", role: "president")
    end
    assert_equal [:inclusion], error.record.errors.details[:role].map { |d| d[:error] }
    assert_equal 0, ReleaseConductorClaim.count, "an invalid role must not create a lease"
  end

  test "[unit] a uniqueness error on an attribute we did NOT look up still raises" do
    record = MigrationLaneClaim.new
    record.errors.add(:some_other_column, :taken)

    refute MigrationLaneClaim.uniqueness_collision_on?(record, [:lane]),
           ":taken on an attribute outside the lookup names a different row than find_by! would return"
  end

  test "[unit] a uniqueness error MIXED with another failure still raises" do
    record = MigrationLaneClaim.new
    record.errors.add(:lane, :taken)
    record.errors.add(:lane, :too_long)

    refute MigrationLaneClaim.uniqueness_collision_on?(record, [:lane]),
           "a record failing for a second reason was never merely a race loser"
  end

  test "[unit] an empty error set is not a race" do
    refute MigrationLaneClaim.uniqueness_collision_on?(MigrationLaneClaim.new, [:lane]),
           "a RecordInvalid carrying no details must propagate, not be read as a collision"
  end

  test "[unit] a plain :taken on a looked-up attribute IS the race" do
    record = MigrationLaneClaim.new
    record.errors.add(:lane, :taken)

    assert MigrationLaneClaim.uniqueness_collision_on?(record, [:lane])
  end
end
