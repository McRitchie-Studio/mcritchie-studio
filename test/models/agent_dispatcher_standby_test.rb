require "test_helper"
require Rails.root.join("bin/lib/agent_domain_registry").to_s

# [unit] The standby role (AgentDispatcher; docs/agents/system/agent-message-loop.md,
# "Warm sessions"): every row is a primary until an admin registers a host; a
# restart inherits its host's role; a standby claims nothing while a primary
# is live and then only its domains' souls; the floor alert's silence reads
# primaries only; prune keeps a host's registration.
class AgentDispatcherStandbyTest < ActiveSupport::TestCase
  setup do
    config = YAML.safe_load_file(AgentMailbox::DomainRegistry::PATH, aliases: false)
    config["domains"]["mcritchie_studio"]["warm_session"] = true
    @registry = AgentMailbox::DomainRegistry.new(config)
  end

  def ping(worker, host:, state: "running")
    AgentDispatcher.ping!({ "worker" => worker, "host" => host, "souls" => %w[avi ray turf_monster], "state" => state })
  end

  test "a new row is a primary; a registered host's restart inherits standby" do
    first = ping("work-1", host: "workmac")
    assert_equal "primary", first.role

    AgentDispatcher.set_role!(host: "workmac", role: "standby", domains: %w[mcritchie_studio], registry: @registry)
    restarted = ping("work-2", host: "workmac")
    assert_equal "standby", restarted.role
    assert_equal %w[mcritchie_studio], restarted.standby_domains
    assert_equal "primary", ping("mac-1", host: "mac").role, "another host is untouched"
  end

  test "set_role! refuses an unknown host, an empty or cold domain list, and an unknown role" do
    assert_raises(ArgumentError) { AgentDispatcher.set_role!(host: "nowhere", role: "standby", domains: %w[mcritchie_studio], registry: @registry) }
    ping("work-1", host: "workmac")
    assert_raises(ArgumentError) { AgentDispatcher.set_role!(host: "workmac", role: "standby", domains: [], registry: @registry) }
    error = assert_raises(ArgumentError) do
      AgentDispatcher.set_role!(host: "workmac", role: "standby", domains: %w[turf_monster], registry: @registry)
    end
    assert_match(/not warm domains/, error.message)
    assert_raises(ArgumentError) { AgentDispatcher.set_role!(host: "workmac", role: "boss", registry: @registry) }
    assert_equal "primary", AgentDispatcher.find_by!(worker_id: "work-1").role
  end

  test "claim_scope: a primary is unchanged; a standby waits on a live primary, then takes only its domains' souls" do
    ping("mac-1", host: "mac")
    ping("work-1", host: "workmac")
    AgentDispatcher.set_role!(host: "workmac", role: "standby", domains: %w[mcritchie_studio], registry: @registry)
    souls = %w[avi ray turf_monster]

    assert_equal [ souls, nil ], AgentDispatcher.claim_scope("mac-1", souls, registry: @registry)
    assert_equal [ souls, nil ], AgentDispatcher.claim_scope("heartbeat-unknown", souls, registry: @registry)
    assert_equal [ [], "standby_primary_live" ], AgentDispatcher.claim_scope("work-1", souls, registry: @registry)

    later = Time.current + AgentDispatcher::SILENT_AFTER + 1
    scope, reason = AgentDispatcher.claim_scope("work-1", souls, now: later, registry: @registry)
    assert_nil reason
    assert_equal %w[avi ray], scope, "turf_monster is not a standby domain's soul"
  end

  test "a primary's graceful stop frees the standby at once" do
    ping("mac-1", host: "mac")
    assert AgentDispatcher.primary_live?
    ping("mac-1", host: "mac", state: "stopping")
    assert_not AgentDispatcher.primary_live?
  end

  test "silence reads primaries only, and prune keeps a host's standby row" do
    old = ping("mac-1", host: "mac")
    old.update_columns(last_seen_at: 10.minutes.ago)
    ping("work-1", host: "workmac")
    AgentDispatcher.set_role!(host: "workmac", role: "standby", domains: %w[mcritchie_studio], registry: @registry)
    assert AgentDispatcher.silent?, "a live standby never hides a silent primary"

    AgentDispatcher.find_by!(worker_id: "work-1").update_columns(last_seen_at: 9.days.ago)
    ping("mac-2", host: "mac")
    AgentDispatcher.prune!
    assert AgentDispatcher.exists?(worker_id: "work-1"), "the host's registration survives a long stop"
  end

  test "the floor alert names a live standby while the primary is silent" do
    ping("mac-1", host: "mac").update_columns(last_seen_at: 10.minutes.ago)
    ping("work-1", host: "workmac")
    AgentDispatcher.set_role!(host: "workmac", role: "standby", domains: %w[mcritchie_studio], registry: @registry)
    check = AgentMessages::FloorAlert.new(routes: AgentMessages::Routes.new({})).dispatcher_check(Time.current)
    assert check.failing
    assert_equal [ "mac", "workmac" ], check.detail.values_at("host", "standby_host")
  end
end
