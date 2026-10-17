require "test_helper"
require "rake"
require "zlib"
require Rails.root.join("bin/lib/agent_domain_registry").to_s

# [unit] The operator's switches for the standby and warm sessions:
# agent_dispatchers:role registers a host (refusing a cold domain),
# agent_dispatchers:sessions reads each lease, and reset_session starts a
# domain fresh.
class AgentDispatchersRakeTest < ActiveSupport::TestCase
  DOMAIN = "mcritchie_studio".freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("agent_dispatchers:role")
    config = YAML.safe_load_file(AgentMailbox::DomainRegistry::PATH, aliases: false)
    config["domains"][DOMAIN]["warm_session"] = true
    AgentProposal.registry = AgentMailbox::DomainRegistry.new(config)
    AgentDispatcher.ping!({ "worker" => "work-1", "host" => "workmac" })
  end

  teardown { AgentProposal.reset_registry! }

  def run_task(name, env)
    saved = env.keys.to_h { |k| [ k, ENV[k] ] }
    env.each { |k, v| ENV[k] = v }
    Rake::Task[name].reenable
    exited = nil
    out, = capture_io do
      Rake::Task[name].invoke
    rescue SystemExit => e
      exited = e
    end
    raise exited if exited

    out
  ensure
    saved.each { |k, v| ENV[k] = v }
  end

  test "role registers a standby for warm domains, and refuses a cold one" do
    out = run_task("agent_dispatchers:role", { "HOST" => "workmac", "ROLE" => "standby", "DOMAINS" => DOMAIN })
    assert_includes out, "workmac: standby for #{DOMAIN}"
    assert_equal "standby", AgentDispatcher.find_by!(worker_id: "work-1").role

    assert_raises(SystemExit) do
      run_task("agent_dispatchers:role", { "HOST" => "workmac", "ROLE" => "standby", "DOMAINS" => "turf_monster" })
    end
    assert_equal [ DOMAIN ], AgentDispatcher.find_by!(worker_id: "work-1").standby_domains
  end

  test "sessions lists each lease; reset_session drops the head, checkpoint and lease" do
    taken = AgentDomainSession.acquire!(domain: DOMAIN, worker: "mac-1")
    row = taken.row
    row.checkpoint!(worker: "mac-1", lease_key: taken.lease_key, session_id: "sess-0001", data: Zlib.gzip("x"), turns: 3, context_tokens: 9)
    assert_match(/#{DOMAIN} gen=1 turns=3 .*held by mac-1/, run_task("agent_dispatchers:sessions", {}))

    run_task("agent_dispatchers:reset_session", { "DOMAIN" => DOMAIN })
    row.reload
    assert_equal [ nil, nil, 0, nil ], [ row.holder, row.claude_session_id, row.turns, row.checkpointed_at ]
  end
end
