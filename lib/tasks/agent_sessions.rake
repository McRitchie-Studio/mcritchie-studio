# frozen_string_literal: true

# The operator's grant of an ADMIN agent session, from a shell on the hub
# (docs/agents/system/agent-sessions-design.md, section 3).
#
#   bin/rails agent_sessions:grant_admin                  Xan, 8 hours
#   bin/rails agent_sessions:grant_admin SOUL=steffon HOURS=1
#
# A shell on the hub IS the grant: whoever can run this can already write the
# database, so it adds a named, logged door and no new power. The board's grant
# is AgentLoginRequest (the Approve tap, or the one-time code).
#
# STDOUT IS THE TOKEN AND NOTHING ELSE, so it can be taken without being read:
#
#   export AGENT_ADMIN_SESSION_TOKEN="$(bin/rails agent_sessions:grant_admin)"
#
# Everything a person reads (who, which session, when it ends) goes to stderr.
# The token is a bearer for every admin-tier endpoint until the session expires
# or is revoked (DELETE /api/v1/agent_sessions/current): do not paste it into a
# chat, a log or a file in a repo.
namespace :agent_sessions do
  desc "Grant an admin agent session (SOUL=xan|steffon, HOURS=1..8) and print its token on stdout"
  task grant_admin: :environment do
    session = AgentSession.grant_admin!(soul: ENV["SOUL"].presence || "xan", hours: ENV["HOURS"].presence)
    warn "admin session #{session.slug} granted to #{session.soul} (#{session.tier}), ends #{session.expires_at.utc.iso8601}. " \
         "Its token is on stdout; revoke it with DELETE /api/v1/agent_sessions/current."
    puts session.token
  rescue ActiveRecord::RecordInvalid => e
    abort "agent_sessions:grant_admin: #{e.record.errors.full_messages.to_sentence}"
  rescue ArgumentError => e
    abort "agent_sessions:grant_admin: #{e.message}"
  end

  # A client runtime key: the credential a sibling app's runtime holds for the
  # endpoints AgentSession::CLIENT_ENDPOINTS names for its soul. No expiry;
  # revoke it with agent_sessions:revoke. STDOUT IS THE KEY AND NOTHING ELSE:
  #
  #   bin/rails agent_sessions:grant_runtime_key SOUL=turf-monster LABEL=turf-production
  desc "Grant a client runtime key (SOUL=turf-monster, LABEL=<runtime>) and print it on stdout"
  task grant_runtime_key: :environment do
    session = AgentSession.grant_runtime_key!(soul: ENV["SOUL"].presence || "turf-monster", label: ENV["LABEL"])
    warn "runtime key #{session.slug} granted to #{session.soul} for #{session.label}: it reaches " \
         "#{session.client_routes.to_sentence} and nothing else, and has no expiry. Its value is on stdout " \
         "(length #{session.token.length}); revoke it with bin/rails agent_sessions:revoke SLUG=#{session.slug}."
    puts session.token
  rescue ActiveRecord::RecordInvalid => e
    abort "agent_sessions:grant_runtime_key: #{e.record.errors.full_messages.to_sentence}"
  rescue ArgumentError => e
    abort "agent_sessions:grant_runtime_key: #{e.message}"
  end

  desc "List the long-lived keys (harness keys and client runtime keys); never a value"
  task keys: :environment do
    rows = AgentSession.granted_keys.order(:issued_at).map do |key|
      state = key.revoked? ? "revoked #{key.revoked_at.utc.iso8601} by #{key.revoked_by}" : "live"
      [ key.slug, key.tier, key.soul, key.label.to_s, key.issued_by, key.issued_at.utc.iso8601, state ].join("  ")
    end
    puts rows.empty? ? "no harness key or runtime key has been granted" : rows
  end

  desc "Revoke an agent session or key at once (SLUG=sess-…, BY=<who>)"
  task revoke: :environment do
    session = AgentSession.find_by(slug: ENV["SLUG"].to_s)
    abort "agent_sessions:revoke: no agent session #{ENV["SLUG"].inspect}; list the keys with bin/rails agent_sessions:keys" unless session
    abort "agent_sessions:revoke: #{session.slug} was already revoked at #{session.revoked_at.utc.iso8601}" if session.revoked?

    session.revoke!(by: ENV["BY"].presence || "operator")
    puts "#{session.slug} (#{session.tier}, #{session.soul}#{" · #{session.label}" if session.label.present?}) is revoked; its next call answers 401."
  end
end
