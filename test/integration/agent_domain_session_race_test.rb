require "test_helper"
require Rails.root.join("bin/lib/agent_domain_registry").to_s

# [integration] The warm-session lease under real database concurrency
# (AgentDomainSession.acquire!): two dispatchers acquiring one domain at the
# same instant, each on its own connection, on a domain with no row yet and on
# a lapsed lease. Exactly one wins every round; the other is refused
# LEASE_HELD, never handed the same lease.
class AgentDomainSessionRaceTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  DOMAIN = "mcritchie_studio".freeze

  setup do
    config = YAML.safe_load_file(Rails.root.join("config/agent_domains.yml"), aliases: false)
    config["domains"][DOMAIN]["warm_session"] = true
    @registry = AgentMailbox::DomainRegistry.new(config)
    AgentDomainSession.where(domain: DOMAIN).delete_all
  end

  teardown { AgentDomainSession.where(domain: DOMAIN).delete_all }

  def acquire_in_parallel(now)
    gate = Queue.new
    threads = %w[mac-1 work-1].map do |worker|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          result = AgentDomainSession.acquire!(domain: DOMAIN, worker: worker, now: now, registry: @registry)
          result.row ? worker : result.refused.code
        end
      end
    end
    2.times { gate << :go }
    threads.map(&:value)
  end

  test "two first acquirers at once: one holds the lease, the other is refused" do
    10.times do |round|
      AgentDomainSession.where(domain: DOMAIN).delete_all
      results = acquire_in_parallel(Time.current)
      winners = results - [ "LEASE_HELD" ]
      assert_equal 1, winners.size, "round #{round}: #{results.inspect}"
      assert_equal winners.first, AgentDomainSession.find_by!(domain: DOMAIN).holder
    end
  end

  test "two acquirers of a lapsed lease at once: one takes it over" do
    AgentDomainSession.create!(domain: DOMAIN, holder: "dead-1", lease_expires_at: 1.minute.ago)
    10.times do |round|
      AgentDomainSession.where(domain: DOMAIN).update_all(holder: "dead-1", lease_expires_at: 1.minute.ago)
      results = acquire_in_parallel(Time.current)
      assert_equal 1, (results - [ "LEASE_HELD" ]).size, "round #{round}: #{results.inspect}"
    end
  end
end
