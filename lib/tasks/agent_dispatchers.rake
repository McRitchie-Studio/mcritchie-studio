# The board-side switches for bin/dispatcher (docs/agents/agents/steffon/sops/agent-dispatcher.md,
# "Standby on a second machine"; docs/agents/system/agent-message-loop.md, "Warm sessions").
#
#   bin/rails agent_dispatchers:list
#   bin/rails agent_dispatchers:role HOST=<short hostname> ROLE=standby DOMAINS=mcritchie_studio[,turf_monster]
#   bin/rails agent_dispatchers:role HOST=<short hostname> ROLE=primary
#   bin/rails agent_dispatchers:sessions          (each warm domain's lease and checkpoint)
#   bin/rails agent_dispatchers:reset_session DOMAIN=<key>   (start the domain's session fresh)
#
# A standby is OFF until someone runs the role task for the work machine's host.
namespace :agent_dispatchers do
  desc "List dispatcher rows: host, role, standby domains, last ping"
  task list: :environment do
    AgentDispatcher.newest_first.limit(20).each do |row|
      domains = row.role == "standby" ? " domains=#{Array(row.standby_domains).join(',')}" : ""
      puts "#{row.worker_id} host=#{row.host} role=#{row.role}#{domains} state=#{row.state || '-'} " \
           "last_seen=#{row.last_seen_at.utc.iso8601}"
    end
  end

  desc "Register a host's dispatcher role (HOST, ROLE=primary|standby, DOMAINS=a,b for a standby)"
  task role: :environment do
    count = AgentDispatcher.set_role!(host: ENV.fetch("HOST"), role: ENV.fetch("ROLE"),
                                      domains: ENV["DOMAINS"].to_s.split(","))
    puts "#{ENV['HOST']}: #{ENV['ROLE']}#{" for #{ENV['DOMAINS']}" if ENV['ROLE'] == 'standby'} (#{count} row(s))"
  rescue ArgumentError, KeyError => e
    abort "agent_dispatchers:role: #{e.message}"
  end

  desc "List each warm domain's session lease, head, checkpoint and last reported fault"
  task sessions: :environment do
    rows = AgentDomainSession.order(:domain)
    puts "no warm sessions yet" if rows.empty?
    rows.each do |row|
      lease = row.lease_live? ? "held by #{row.holder} until #{row.lease_expires_at.utc.iso8601}" : "free"
      puts "#{row.domain} gen=#{row.generation} turns=#{row.turns} context=#{row.context_tokens} #{lease} " \
           "checkpoint=#{row.checkpoint_bytes || 0}B@#{row.checkpointed_at&.utc&.iso8601 || '-'}" \
           "#{' handback requested' if row.handback_requested?}" \
           "#{" FAULT #{row.last_fault} @#{row.last_fault_at&.utc&.iso8601}" if row.last_fault.present?}"
    end
  end

  desc "Start a warm domain's session fresh (DOMAIN): drops its head, checkpoint and lease"
  task reset_session: :environment do
    row = AgentDomainSession.find_by!(domain: ENV.fetch("DOMAIN"))
    row.reset!
    puts "#{row.domain}: session cleared; the next warm turn starts fresh (generation #{row.generation})"
  rescue KeyError, ActiveRecord::RecordNotFound => e
    abort "agent_dispatchers:reset_session: #{e.message}"
  end
end
