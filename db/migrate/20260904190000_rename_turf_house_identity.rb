# frozen_string_literal: true

# THE ORPHAN ADMIN. The Turf Monster house identity moved off
# `turf@mcritchie.studio` onto the real Google user `team@turfmonster.media`
# (1Password `google.turf.agents`) on 2026-09-04, and was demoted from admin to
# viewer in the same pass.
#
# The demotion reaches an existing row on its own — `assign_parked_identity`
# re-reads `User::PARKED_IDENTITIES` by email on every save. The RENAME cannot:
# once the roster no longer lists `turf@mcritchie.studio`, the row sitting on it
# matches no parked identity at all, so nothing ever re-reads it and it keeps the
# role it was last saved with. Which is ADMIN — on an address whose Google group
# is being deleted, so no one is even reading the mail at it. That is the exact
# shape of a credential nobody is watching, and it is why this is a migration
# rather than a line in the seed: the release phase here is `bin/rails db:migrate`
# alone (see Procfile), and `bin/dor-check` refuses a bare `db:seed` as a
# post-deploy command, so a migration is the ONLY thing that reaches production.
#
# It spells the pair out instead of reading `User::RETIRED_EMAILS`. A migration is
# a historical record that must still run against whatever `User` has become years
# from now; a constant is a live fact that gets renamed and deleted. The seed reads
# the constant, this does not, and they are checked against each other by
# `test/models/retired_emails_test.rb`.
class RenameTurfHouseIdentity < ActiveRecord::Migration[8.1]
  OLD_EMAIL = "turf@mcritchie.studio"
  NEW_EMAIL = "team@turfmonster.media"

  # Raw SQL, no model. Loading `User` here would drag in `assign_parked_identity`,
  # `has_authentication_method` and Sluggable's before_save — and Sluggable rebuilds
  # the slug on every save, so an incidental save is how a row silently changes the
  # URL it answers on.
  def up
    move(from: OLD_EMAIL, to: NEW_EMAIL, role: "viewer")
  end

  # Reversible so a rollback does not strand the row on an address the roster of
  # that older revision does not list. Restores the admin role it held then.
  def down
    move(from: NEW_EMAIL, to: OLD_EMAIL, role: "admin")
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

  def sanitize(sql, *binds) = ActiveRecord::Base.sanitize_sql_array([sql, *binds])

  def select_one(sql) = ActiveRecord::Base.connection.select_one(sql)
end
