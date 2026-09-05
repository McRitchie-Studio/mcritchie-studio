# frozen_string_literal: true

# THE ROWS THE PREVIOUS RENAME ALREADY WROTE.
#
# `users.first_name`/`last_name` are derived from `name` by
# `before_save :set_name_parts`. `RenameTurfHouseIdentity#rename` writes `name`
# with raw SQL, so it skipped that callback, and the callback is gated on
# `name_changed?` — meaning no later save ever notices. A row renamed
# "McRitchie Studio Team" -> "Team McRitchie" therefore kept McRitchie/Team, which
# is not merely stale: it is the row's own name backwards, and it is what
# /profile/edit puts in the First name box.
#
# That writer is fixed in place, so a database migrating from scratch now lands
# consistent. This is the other half: a database that ALREADY RAN it will never
# run it again, so its row stays fossilised until something repairs it. Measured
# 2026-09-05 — mcritchie-studio-qa held exactly one such row (team@mcritchie.studio,
# name "Team McRitchie", first_name "McRitchie", last_name "Team"); production held
# none, because no row sits on that address there.
#
# WHY THIS IS NARROW RATHER THAN A SWEEP. "Resync every row whose halves disagree
# with its name" would be shorter and would destroy data: the engine's profile form
# (Studio::ProfilesController#name_attributes) and its onboarding step both write
# `first_name`/`last_name` DIRECTLY and only backfill `name` when it is blank, so a
# disagreement is just as likely to be a deliberate edit as a fossil. The guard
# below repairs only a row whose halves are exactly what the OLD name derives —
# the fingerprint of this specific skipped callback and of nothing else. Same
# discipline as the rename it repairs, which only rewrites the name the roster
# itself planted.
#
# It spells the pair out instead of reading `User::RETIRED_NAMES`, for the reason
# its sibling gives: a migration is a historical record that must still run against
# whatever `User` has become years from now. `test/models/renamed_name_parts_test.rb`
# asserts the copies still agree today, which is the only day both exist.
class SyncRenamedUserNameParts < ActiveRecord::Migration[8.1]
  # email => [name it was renamed FROM, name it was renamed TO].
  RENAMED = { "team@mcritchie.studio" => ["McRitchie Studio Team", "Team McRitchie"] }.freeze

  def up
    RENAMED.each { |email, (was, now)| resync(email, was: was, now: now) }
  end

  # Nothing to undo. The halves this wrote are the ones the row's own name derives,
  # and `RenameTurfHouseIdentity#down` now carries them back with the name it
  # restores — so a rollback that passes through both files lands consistent
  # without this one saying anything.
  def down
    say "derived name parts need no rollback; the rename migration carries them both ways"
  end

  private

  def resync(email, was:, now:)
    old_first, old_last = name_parts(was)
    new_first, new_last = name_parts(now)

    if [old_first, old_last] == [new_first, new_last]
      return say("#{email}: both names derive the same halves — nothing to repair")
    end

    # `IS NOT DISTINCT FROM` rather than `=`, because either column may be NULL and
    # a NULL must compare as a match, not swallow the row.
    changed = update_rows(sanitize(
                            "UPDATE users SET first_name = ?, last_name = COALESCE(?, last_name), " \
                            "updated_at = NOW() WHERE LOWER(email) = ? AND name = ? " \
                            "AND first_name IS NOT DISTINCT FROM ? AND last_name IS NOT DISTINCT FROM ?",
                            new_first, new_last, email, now, old_first, old_last
                          ))

    if changed.positive?
      say "#{email}: name parts resynced to #{new_first.inspect}/#{new_last.inspect}"
    else
      say "#{email}: no row carrying the old name's parts — nothing to repair"
    end
  end

  # First and last WORD, and `nil` for a last name a one-word name cannot supply.
  # The same derivation `User.name_parts` runs, inlined for the reason in the header.
  def name_parts(name)
    words = name.to_s.strip.split(" ")
    [words.first, (words.last if words.size > 1)]
  end

  def sanitize(sql, *binds) = ActiveRecord::Base.sanitize_sql_array([sql, *binds])

  # The connection's `update` hands back the affected row count, which is what
  # turns "I ran an UPDATE" into "I changed something". Named `update_rows` so it
  # cannot shadow what `ActiveRecord::Migration` already delegates under `update`.
  def update_rows(sql) = ActiveRecord::Base.connection.update(sql)
end
