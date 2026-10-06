# The hub is passwordless (magic link + Google), but production still held a
# password digest for 3 of its 8 users (2026-10-06), and studio-engine up to 0.90
# draws POST /login, which signs in whoever presents a matching password. User
# dropped has_secure_password and ignores the column in the same change; this
# clears the digests themselves, so no stored password survives to be guessed.
#
# Nulled rather than dropped: the dynos still running the previous release keep
# password_digest in their schema cache until they restart, and a column dropped
# under them fails every User insert in that window. A later release drops it.
#
# /tasks/hub-drops-stale-password-digests
class NullUserPasswordDigests < ActiveRecord::Migration[8.1]
  def up
    execute "UPDATE users SET password_digest = NULL WHERE password_digest IS NOT NULL"
  end

  # Nothing to restore: the digests were the defect, and rolling the schema back
  # must not need them.
  def down; end
end
