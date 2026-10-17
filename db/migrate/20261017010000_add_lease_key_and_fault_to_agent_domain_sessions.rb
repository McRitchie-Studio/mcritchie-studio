# Warm-session hardening (review of warm-domain-session-standby; plan:
# .agents/epics/domain-agents.md, "Before any domain sets warm_session: true").
#
# lease_key_digest   the SHA-256 of the secret the board hands the acquirer of
#                    a lease, once. Every holder verb (renew, checkpoint, the
#                    checkpoint read, release, consolidate, fault) must present
#                    it, so the shared agent token plus a holder's name (which
#                    GET index shows) no longer reads or writes a session.
# last_fault*        the holder's report that a checkpoint or a restore failed,
#                    so a domain that has gone cold says so on the board (and in
#                    ErrorLog) instead of only in one machine's log.
#
# Additive and nullable: every row (none is warm yet) reads as no lease key,
# which no caller can match, so the next acquire mints one.
class AddLeaseKeyAndFaultToAgentDomainSessions < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_domain_sessions, :lease_key_digest, :string
    add_column :agent_domain_sessions, :last_fault, :string
    add_column :agent_domain_sessions, :last_fault_at, :datetime
  end
end
