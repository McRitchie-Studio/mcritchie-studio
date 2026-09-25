# frozen_string_literal: true

# A development-env rails command inside a desk refuses the SHARED development DB.
# Runs after dotenv (before_configuration), so the desk's .env.development.local is
# already in ENV. See lib/desk_database_guard.rb.
require Rails.root.join("lib/desk_database_guard").to_s

if Rails.env.development?
  refusal = DeskDatabaseGuard.refusal(
    root: Rails.root.to_s,
    rails_env: Rails.env,
    database_url: ENV["DATABASE_URL"],
    shared_database: Rails.application.config.database_configuration.dig("development", "database"),
    override: ENV[DeskDatabaseGuard::OVERRIDE]
  )
  abort(refusal) if refusal
end
