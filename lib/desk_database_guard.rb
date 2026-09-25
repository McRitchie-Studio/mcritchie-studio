# frozen_string_literal: true

# DESK DATABASE GUARD — a development-env rails command inside a desk
# (`<repo>/.worktrees/<slug>`) refuses to run against the SHARED development DB.
#
# THE DEFECT (2026-09-25): three builders ran `bin/rails db:prepare` in a fresh desk
# and hit the shared mcritchie_studio_development, because nothing pointed the desk's
# development env at its own DB. bin/agent-worktree now writes .env.development.local
# (see write_dev_env_local); this guard is the net for a desk that predates that, or
# whose pointer was deleted. Pure: config/initializers/desk_database_guard.rb feeds it.
module DeskDatabaseGuard
  OVERRIDE = "ALLOW_SHARED_DEV_DB"
  DESK_ROOT = %r{/\.worktrees/(?<slug>[^/]+)/?\z}

  module_function

  # -> nil (proceed) or the refusal message.
  def refusal(root:, rails_env:, database_url:, shared_database:, override: nil)
    return nil unless rails_env.to_s == "development"
    return nil unless (match = DESK_ROOT.match(root.to_s))
    return nil unless override.to_s.strip.empty?
    return nil unless effective_database(database_url, shared_database) == shared_database

    slug = match[:slug]
    <<~MSG
      ✗ refusing to run against the SHARED development database (#{shared_database}) from desk #{slug}.
        This desk has no development pointer of its own, so a bare `bin/rails` falls back to the
        database the primary and every other desk share. Write the desk's pointer with:
          bin/agent-worktree new mcritchie-studio #{slug}
        (Test work needs no pointer: prefix it with RAILS_ENV=test. Meant it? #{OVERRIDE}=1.)
    MSG
  end

  # The DB name Rails will connect to: DATABASE_URL's path when set, else database.yml's.
  def effective_database(database_url, configured)
    url = database_url.to_s.strip
    return configured if url.empty?

    url.split("?", 2).first.split("/").last.to_s
  end
end
