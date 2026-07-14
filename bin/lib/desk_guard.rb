# frozen_string_literal: true

# DeskGuard — refuse a test lane in a worktree DESK that has no isolated test DB.
#
# A desk (an agent worktree at <repo>/.worktrees/<slug>) gets its OWN test database,
# pinned by TEST_DATABASE_URL in .env.test.local, which bin/agent-worktree writes at
# bringup. config/database.yml renders `url: <%= ENV["TEST_DATABASE_URL"] %>` and falls
# back to the SHARED base `<app>_test` when it is blank — so a desk whose bringup did
# not complete does not fail loudly. It QUIETLY JOINS the database the primary checkout
# and the release gate workspaces run on: cross-suite pollution, PG::ObjectInUse on
# purge, order-dependent phantom failures. Nothing about the directory announces it.
#
# bin/agent-worktree's bringup is now atomic and cannot leave such a desk behind. This
# is the second lock on the same door, and it is worth more than the first: desks
# half-built by the OLD tool are still on disk, .env.test.local can be deleted by hand,
# and a rollback that misses a case must still never yield a silently-shared suite. So
# the property is ASSERTED at USE time rather than trusted to have been set up right —
# the same "assert first, destroy second" the gate workspaces use before they purge.
#
# The invariant is POSITIVE — "this tree has a test DB of its own" — not a blacklist of
# the ways bringup can break, so a break nobody imagined still refuses. It is satisfied by
# a TEST_DATABASE_URL from EITHER .env.test.local or the process env, so a caller that
# exports one (Release::GateEnv does) passes without being named.
#
# It guards AGENT DESKS only. `.worktrees/` also holds the release gate/ship workspaces
# (`_gate`, `_ship`), whose leading underscore is a namespace Release::GateWorkspace
# reserves precisely so they are "NOT an agent worktree and must never be mistaken for
# one". They are not exempt from the rule so much as covered by their own, stricter one:
# assert_private_gate_db! proves their DB is private BEFORE db:test:purge destroys it. And
# a SQLite app's workspace (rolio) has NO TEST_DATABASE_URL by design — its test DB is a
# file inside the workspace, already private — so demanding one there would refuse a
# perfectly isolated tree.
module DeskGuard
  module_function

  WORKTREES_DIR = ".worktrees"
  TEST_ENV_LOCAL = ".env.test.local"
  # Release::GateWorkspace::DIRNAME — `_gate` / `_ship`, and any future sibling.
  RESERVED_PREFIX = "_"

  # nil when `root` may run a test lane; otherwise the refusal message.
  # A non-desk root (the primary checkout, CI, a bare clone) is never refused — the
  # shared `<app>_test` DB is the CORRECT database there.
  def refusal(root, env: ENV)
    return nil unless desk?(root)
    return nil if present?(env["TEST_DATABASE_URL"])
    return nil if present?(declared_test_database_url(root))

    <<~MSG.strip
      this worktree has no isolated test DB — its bringup did not complete.

        desk:    #{File.expand_path(root.to_s)}
        missing: #{TEST_ENV_LOCAL} (TEST_DATABASE_URL=…), and none is exported in the env

      Without it, RAILS_ENV=test silently falls back to the SHARED base test database —
      the one the primary checkout and the release gate workspaces use — so this run would
      pollute, and be polluted by, every concurrent suite. Refusing: a cert against a shared
      database certifies nothing.

      This is an ENV issue with the DESK, not a regression in your diff. Re-provision it
      (bringup is idempotent and repairs the missing pieces):

        bin/agent-worktree new <app> #{File.basename(File.expand_path(root.to_s))}
    MSG
  end

  # A tree is an agent desk when it sits directly under a repo's .worktrees/ and is not
  # one of the reserved `_`-prefixed release workspaces. Checked on the PATH, not on the
  # stack env: a half-built desk is missing exactly those files, so keying the check on
  # them would let the broken case walk straight through.
  def desk?(root)
    path = File.expand_path(root.to_s)
    return false unless File.basename(File.dirname(path)) == WORKTREES_DIR

    !File.basename(path).start_with?(RESERVED_PREFIX)
  end

  # TEST_DATABASE_URL as declared by the desk's .env.test.local, or nil.
  def declared_test_database_url(root)
    path = File.join(File.expand_path(root.to_s), TEST_ENV_LOCAL)
    return nil unless File.exist?(path)

    File.readlines(path).each do |line|
      key, _, value = line.strip.partition("=")
      return value.strip if key.strip == "TEST_DATABASE_URL"
    end
    nil
  rescue SystemCallError
    nil
  end

  def present?(value)
    !value.to_s.strip.empty?
  end
end
