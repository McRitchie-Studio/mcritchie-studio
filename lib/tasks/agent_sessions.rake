# frozen_string_literal: true

# The operator's grant of an ADMIN agent session, from a shell on the hub
# (docs/agents/system/agent-sessions-design.md, section 3).
#
#   bin/rails agent_sessions:grant_admin                  Xan, 8 hours
#   bin/rails agent_sessions:grant_admin SOUL=steffon HOURS=1
#
# A shell on the hub IS the grant: whoever can run this can already write the
# database, so it adds a named, logged door and no new power. The Approve tap
# the design describes is not built; this is the grant until it is.
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
end
