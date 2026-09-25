# frozen_string_literal: true

# DESK DATABASE GUARD — a development-env rails command inside a desk
# (`<repo>/.worktrees/<slug>`) refuses to run against the SHARED development DB.
#
# THE DEFECT (2026-09-25): three builders ran `bin/rails db:prepare` in a fresh desk
# and hit the shared mcritchie_studio_development, because nothing pointed the desk's
# development env at its own DB. bin/agent-worktree now writes .env.development.local
# (see write_dev_env_local); this guard is the net for a desk that predates that, or
# whose pointer was deleted. Pure: config/initializers/desk_database_guard.rb feeds it.
require "uri"

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
        #{why(database_url)}
        Write the desk's own pointer with:
          bin/agent-worktree new mcritchie-studio #{slug}
        (Test work needs no pointer: prefix it with RAILS_ENV=test. Meant it? #{OVERRIDE}=1.)
    MSG
  end

  # The refusal names the cause it actually saw: no pointer at all, or a pointer that
  # resolves to the shared DB (named outright, or host-only with no database path).
  def why(database_url)
    if database_url.to_s.strip.empty?
      "This desk has no development pointer (DATABASE_URL is unset), so a bare `bin/rails`\n  " \
        "falls back to the database the primary and every other desk share."
    else
      "This desk's DATABASE_URL resolves to the shared database, so a bare `bin/rails`\n  " \
        "would read and write the database the primary and every other desk share."
    end
  end

  # The DB name Rails will connect to: DATABASE_URL's path when it names one, else
  # database.yml's. A host-only URL (postgresql://localhost, or a trailing "/") names
  # no database, and Rails merges it over database.yml — so it connects to `configured`.
  def effective_database(database_url, configured)
    url = database_url.to_s.strip
    return configured if url.empty?

    path = begin
      URI.parse(url).path.to_s
    rescue URI::InvalidURIError
      url.split("?", 2).first.sub(%r{\A[a-z][a-z0-9+.-]*://[^/]*}i, "")
    end
    name = URI.decode_www_form_component(path.delete_prefix("/"))
    name.empty? ? configured : name
  end
end
