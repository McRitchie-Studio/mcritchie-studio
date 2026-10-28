# A satellite app's own credential to a hub API (AppCredential; today the agent
# chat, Api::V1::AgentChatsController). Run where the hub's database is:
#
#   heroku run -a mcritchie-studio bin/rails app_credentials:mint APP=alex-build
#   bin/rails app_credentials:list
#   bin/rails app_credentials:revoke APP=alex-build
#
# mint prints the secret ONCE: file it in 1Password as `apps.<slug>.agent-chat`
# (the credential-filing SOP) and set it as the app's AGENT_CHAT_TOKEN. The hub
# keeps only its digest, so a lost secret is re-minted, never recovered; minting
# again revokes the old one. Never paste the printed secret into a chat, a card
# or a commit.
namespace :app_credentials do
  desc "Mint an app's agent-chat credential (APP=<slug>, PURPOSE=agent-chat); prints the secret once"
  task mint: :environment do
    app = ENV.fetch("APP").to_s.strip
    purpose = ENV.fetch("PURPOSE", "agent-chat")
    routes = AgentMessages::Routes.current
    if purpose == "agent-chat" && routes.web_apps.fetch(app, []).empty?
      abort "#{app} is not under `web: apps:` in config/agent_routes.yml, so an agent-chat credential would reach nothing. " \
            "List the app and the souls it may address first."
    end

    row, secret = AppCredential.issue!(app_slug: app, purpose: purpose, label: ENV["LABEL"],
                                       issued_by: ENV["BY"].presence || ENV["USER"].presence || "rake")
    puts "Minted #{purpose} credential ##{row.id} for #{app} (older live ones revoked)."
    puts "File it in 1Password as apps.#{app}.#{purpose} and set the app's AGENT_CHAT_TOKEN. It is not shown again:"
    puts secret
  end

  desc "List app credentials (never their secrets)"
  task list: :environment do
    AppCredential.order(:app_slug, :purpose, :id).each do |row|
      state = row.revoked? ? "revoked #{row.revoked_at.utc.iso8601}" : "live"
      puts format("#%-5d %-24s %-12s %-30s last used %s", row.id, row.app_slug, row.purpose, state,
                  row.last_used_at&.utc&.iso8601 || "never")
    end
  end

  desc "Revoke an app's live credentials (APP=<slug>, PURPOSE=agent-chat)"
  task revoke: :environment do
    app = ENV.fetch("APP").to_s.strip
    rows = AppCredential.live.where(app_slug: app, purpose: ENV.fetch("PURPOSE", "agent-chat"))
    count = rows.count
    rows.find_each { |row| row.revoke!(by: ENV["BY"].presence || ENV["USER"].presence || "rake") }
    puts "Revoked #{count} live credential(s) for #{app}."
  end
end
