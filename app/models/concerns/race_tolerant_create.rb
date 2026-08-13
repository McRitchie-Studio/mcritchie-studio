# frozen_string_literal: true

# Find-or-create for a SINGLETON row that two first-acquirers may reach at once —
# the create race every claim/lease model in this app runs (MigrationLaneClaim,
# DevopsShift, TaskReviewClaim, ReleaseConductorClaim). The loser must re-read the
# winner's row and go on to contend for it normally; it must never see an
# exception, because the whole point of these models is to ANSWER "who holds it".
#
# WHY A SHARED HELPER AND NOT `rescue RecordNotUnique` AT EACH CALL SITE. That
# rescue — which all four models hand-rolled identically — covers only HALF the
# race window, and the uncovered half is the likelier one. `find_or_create_by!`
# issues three statements, and a concurrent commit can land in either gap:
#
#   1. SELECT … WHERE lane = ?          ← find_or_create_by!'s own lookup, misses
#      ─ gap A ─                          winner commits HERE → step 2 sees it
#   2. SELECT 1 … WHERE lane = ? LIMIT 1 ← the uniqueness VALIDATOR's read
#      ─ gap B ─                          winner commits HERE → step 3 collides
#   3. INSERT …                         ← the unique index fires
#
# A commit in **gap B** trips the database constraint: `ActiveRecord::RecordNotUnique`.
# A commit in **gap A** is caught earlier, by the model's own `uniqueness: true`
# validator, which raises `ActiveRecord::RecordInvalid` — a DIFFERENT class that
# the hand-rolled rescue never named. (Both gaps are reachable because Postgres
# runs READ COMMITTED: every statement takes a fresh snapshot, so a validator
# SELECT inside our open transaction does see another transaction's commit.)
# A commit BEFORE step 1 is not a race at all — the lookup simply finds the row.
#
# So gap A raised out of `acquire` instead of refusing the caller: an intermittent
# CI failure, and worse, a lease model that threw an exception at exactly the
# moment it was supposed to say "held by someone else".
#
# WHY THIS DOES NOT JUST ADD `RecordInvalid` TO THE RESCUE LIST. `RecordInvalid`
# is raised for ANY validation failure. A blanket rescue would swallow a blank
# key, a bad `inclusion:`, or a future validation, then return a row the caller
# never asked for — turning a loud bug into a silent one. So the rescue must
# ESTABLISH that this particular failure is the uniqueness collision on the very
# attributes being looked up, and re-raise everything else untouched.
module RaceTolerantCreate
  extend ActiveSupport::Concern

  class_methods do
    # Find (or create) the singleton row for `attributes`, tolerating a concurrent
    # first-create in EITHER gap above. The loser re-reads the winner's committed
    # row. Any other validation failure propagates unchanged.
    #
    # `find_by!` (not `find_by`) on the retry is deliberate: reaching here means a
    # conflicting row was observed a moment ago, so its absence now is a genuine
    # anomaly (someone deleted the singleton mid-race) and must not be papered
    # over with a nil the caller would dereference.
    def find_or_create_tolerating_race!(attributes)
      find_or_create_by!(attributes)
    rescue ActiveRecord::RecordNotUnique
      find_by!(attributes)
    rescue ActiveRecord::RecordInvalid => e
      raise unless uniqueness_collision_on?(e.record, attributes.keys)

      find_by!(attributes)
    end

    # True only when EVERY error on the record is a uniqueness (`:taken`) error on
    # one of `keys` — the attributes we are about to re-read by. Deliberately
    # strict on both axes:
    #
    #   * the error TYPE — `:blank` on the same attribute still raises, so a
    #     caller that passes a blank key gets told, not handed a stranger's row;
    #   * the error ATTRIBUTE — a `:taken` on some attribute we are NOT looking up
    #     names a different row than the one `find_by!` would return.
    #
    # An empty error set is false: a `RecordInvalid` carrying no details is not a
    # race, and treating it as one would swallow it.
    def uniqueness_collision_on?(record, keys)
      details = record.errors.details
      return false if details.empty?

      details.all? do |attribute, errors|
        keys.include?(attribute) && errors.all? { |error| error[:error] == :taken }
      end
    end
  end
end
