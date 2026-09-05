# frozen_string_literal: true

# THE ORPHAN ADMIN. The Turf Monster house identity moved off
# `turf@mcritchie.studio` onto the real Google user `team@turfmonster.media`
# (1Password `google.turf.agents`) on 2026-09-04, and was demoted from admin to
# viewer in the same pass.
#
# NEITHER HALF REACHES A DEPLOYED ROW ON ITS OWN, and the second half is the one
# that fooled the first draft of this file. `assign_parked_identity` re-reads
# `User::PARKED_IDENTITIES` by email — but only on SAVE, and nothing in a release
# saves these rows. The proof is in the database rather than in an argument:
# mack@mcritchie.studio has been `viewer` in the roster since 2026-08-14 (PR #865)
# and was still `admin` in production twenty-one days later. So a demotion waits
# for its owner to sign in, which for a shared house account may be never.
#
# The RENAME cannot self-heal at all: once the roster no longer lists
# `turf@mcritchie.studio`, the row sitting on it matches no parked identity, so
# nothing ever re-reads it and it keeps the role it was last saved with. Which was
# ADMIN — on an address whose Google group is being deleted, so no one is even
# reading the mail at it. That is the exact shape of a credential nobody is
# watching.
#
# Hence a migration rather than a line in the seed: the release phase here is
# `bin/rails db:migrate` alone (see Procfile), and `bin/dor-check` refuses a bare
# `db:seed` as a post-deploy command, so a migration is the ONLY thing that
# reaches production. It does three things — move the address, reconcile every
# parked row's ROLE against the roster this revision declares, and finish the one
# display-name change the roster cannot make on its own.
#
# It spells the roster out instead of reading `User::PARKED_IDENTITIES`. A
# migration is a historical record that must still run against whatever `User` has
# become years from now; a constant is a live fact that gets renamed and deleted.
# The seed reads the constants, this does not, and `test/models/retired_email_move_test.rb`
# asserts the two copies still agree TODAY — which is the only day both exist.
class RenameTurfHouseIdentity < ActiveRecord::Migration[8.1]
  OLD_EMAIL = "turf@mcritchie.studio"
  NEW_EMAIL = "team@turfmonster.media"

  # The admin line as this revision declares it, spelled out. Reconciling every
  # seat — not just the two this task changes — is what also closes mack's
  # twenty-one-day drift, and it is why re-running is a no-op rather than a bet.
  ROLES = {
    "alex@mcritchie.studio" => "admin",
    "team@mcritchie.studio" => "admin",
    "admin@mcritchie.studio" => "admin",
    "mason@mcritchie.studio" => "viewer",
    "mack@mcritchie.studio" => "viewer",
    NEW_EMAIL => "viewer"
  }.freeze

  # What a rollback restores, and only that. Mason is the seat this revision
  # demoted, so the revision before it declared him an admin. Mack was ALREADY
  # `viewer` in the prior roster (his row merely never caught up), the Turf house
  # account is carried by `move`, and admin@mcritchie.studio did not exist in that
  # roster at all — so a rollback has nothing to say about any of them.
  PRIOR_ROLES = { "mason@mcritchie.studio" => "admin" }.freeze

  # A display name the ROSTER planted and has since changed, email => [was, now].
  # Guarded on the old value: a row whose name someone edited is theirs, not the
  # roster's, and `assign_parked_identity` deliberately only fills a name in when
  # it is blank. Without this the rename lands on the literal in the roster and
  # nowhere else, because nothing in the app ever rewrites a name it did not set.
  RENAMES = { "team@mcritchie.studio" => ["McRitchie Studio Team", "Team McRitchie"] }.freeze

  # Raw SQL, no model. Loading `User` here would drag in `assign_parked_identity`,
  # `has_authentication_method` and Sluggable's before_save. That last one matters:
  # the slug is `"#{name}-#{email}"`, so a full save re-points the URL the row
  # answers on. Raw SQL DEFERS that rewrite rather than preventing it — the row's
  # next ordinary save still re-slugs it — which is safe here only because no table
  # keys off `users.slug` and no route takes a user slug.
  def up
    move(from: OLD_EMAIL, to: NEW_EMAIL, role: "viewer")
    reconcile_roles(ROLES)
    RENAMES.each { |email, (was, now)| rename(email, from: was, to: now) }
  end

  # Reversible so a rollback does not strand the row on an address the roster of
  # that older revision does not list, or leave a seat demoted that it calls an
  # admin.
  def down
    move(from: NEW_EMAIL, to: OLD_EMAIL, role: "admin")
    reconcile_roles(PRIOR_ROLES)
    RENAMES.each { |email, (was, now)| rename(email, from: now, to: was) }
  end

  private

  def move(from:, to:, role:)
    stale = select_one(sanitize("SELECT id FROM users WHERE LOWER(email) = ? LIMIT 1", from))
    return say("no row on #{from} — nothing to move") unless stale

    if select_one(sanitize("SELECT id FROM users WHERE LOWER(email) = ? LIMIT 1", to))
      # BOTH rows exist, which means someone signed in at the new address before
      # this ran. Merging two accounts is a judgment call with wallets and sessions
      # on both sides, so leave that to the operator — but do NOT leave the stale
      # one holding admin, which is the risk this migration exists to close.
      execute(sanitize("UPDATE users SET role = ?, updated_at = NOW() WHERE id = ?", role, stale["id"]))
      say "#{to} is already taken; left #{from} in place as #{role} for a manual merge"
    else
      execute(sanitize("UPDATE users SET email = ?, role = ?, updated_at = NOW() WHERE id = ?", to, role, stale["id"]))
      say "#{from} -> #{to} (#{role})"
    end
  end

  # Guarded on `IS DISTINCT FROM`, so a row already carrying the roster's answer
  # is not touched and its `updated_at` does not move (and a NULL role, which the
  # column allows, still counts as different rather than swallowing the update). Addresses with no row are simply
  # not there to update; this never creates one, because a parked identity that has
  # never signed in is not an account yet.
  def reconcile_roles(roles)
    roles.each do |email, role|
      changed = update_rows(sanitize(
                         "UPDATE users SET role = ?, updated_at = NOW() WHERE LOWER(email) = ? AND role IS DISTINCT FROM ?",
                         role, email, role
                       ))
      say "#{email} -> #{role}" if changed.positive?
    end
  end

  # Carries the DERIVED HALVES with the rename. `users.first_name`/`last_name` are
  # derived from `name` by `before_save :set_name_parts`, and this raw-SQL write
  # skips it — so without this the row keeps the halves of the name it no longer
  # has, and nothing self-heals them: the callback is gated on `name_changed?`, and
  # after a write like this one no later save sees a name change. "McRitchie Studio
  # Team" derives McRitchie/Team and "Team McRitchie" derives Team/McRitchie, so
  # the fossil is not merely stale — it is the row's own name backwards.
  #
  # Derived INLINE rather than through `User.name_parts`, for the same reason this
  # file spells the roster out: a migration must still run against whatever `User`
  # has become years from now. `test/models/renamed_name_parts_test.rb` asserts the
  # two copies still agree, which is the only day both exist.
  def rename(email, from:, to:)
    first, last = name_parts(to)
    changed = update_rows(sanitize(
                            "UPDATE users SET name = ?, first_name = ?, last_name = COALESCE(?, last_name), " \
                            "updated_at = NOW() WHERE LOWER(email) = ? AND name = ?",
                            to, first, last, email, from
                          ))
    say "#{email} renamed #{from.inspect} -> #{to.inspect}" if changed.positive?
  end

  # First and last WORD, and `nil` for a last name a one-word name cannot supply —
  # which the UPDATE above turns into "leave the column alone", matching what the
  # callback does there (`self.last_name = parts.last if parts.size > 1`).
  def name_parts(name)
    words = name.to_s.strip.split(" ")
    [words.first, (words.last if words.size > 1)]
  end

  def sanitize(sql, *binds) = ActiveRecord::Base.sanitize_sql_array([sql, *binds])

  def select_one(sql) = ActiveRecord::Base.connection.select_one(sql)

  # `execute` hands back a driver result; the connection's `update` hands back the
  # affected row count, which is what turns "I ran an UPDATE" into "I changed
  # something". Named `update_rows` rather than `update` so it cannot shadow what
  # `ActiveRecord::Migration` already delegates under that name.
  def update_rows(sql) = ActiveRecord::Base.connection.update(sql)
end
