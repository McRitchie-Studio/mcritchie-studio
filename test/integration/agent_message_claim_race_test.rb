# frozen_string_literal: true

require "test_helper"
require_relative "../support/agent_message_fixtures"

# [integration] Alex McRitchie's three heartbeat scenarios, with the database arbitrating:
# two workers claiming AT ONCE on their own Postgres connections, run serially,
# and two souls side by side.
#
# TRANSACTIONAL FIXTURES ARE OFF, as in review_pending_action_settle_race_test.rb:
# a transactional test pins one shared connection, so two threads would serialise
# on it and FOR UPDATE SKIP LOCKED would never be exercised. Every row here is
# committed, and #cleanup! removes them (events cascade with their message).
class AgentMessageClaimRaceTest < ActiveSupport::TestCase
  include AgentMessageFixtures

  self.use_transactional_tests = false

  THREAD_PREFIX = "race-test:"

  def setup = cleanup!
  def teardown = cleanup!

  def cleanup!
    AgentMessage.where("thread_key LIKE ?", "#{THREAD_PREFIX}%").destroy_all
  end

  def message!(soul: "avi", thread: SecureRandom.hex(4))
    agent_message!(soul: soul, thread_key: "#{THREAD_PREFIX}#{thread}")
  end

  # Both workers wait at the gate, then claim at the same instant, each on its own
  # connection. Thread#value re-raises, so a failure inside a thread fails the test.
  def claim_in_parallel(souls)
    gate = Queue.new
    threads = souls.each_with_index.map do |soul, i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          gate.pop
          AgentMessage.claim!(soul: soul, worker: "parallel-#{i}").message&.id
        end
      end
    end
    souls.size.times { gate << :go }
    threads.map(&:value)
  end

  test "two workers claiming one message at once: exactly one gets it, once" do
    message = message!

    20.times do |round|
      AgentMessage.where(id: message.id).update_all(status: "received", claimed_by: nil, lease_expires_at: nil, attempts: 0)
      results = claim_in_parallel(%w[avi avi])

      assert_equal [ message.id ], results.compact, "round #{round}: #{results.inspect}"
    end
  end

  test "two workers, two messages in two threads: each gets a different one" do
    a = message!
    b = message!
    results = claim_in_parallel(%w[avi avi])

    assert_equal [ a.id, b.id ].sort, results.compact.sort
  end

  test "two workers, two messages in ONE thread: the second waits, nobody double-reads" do
    first = message!(thread: "shared")
    message!(thread: "shared")

    10.times do
      AgentMessage.where("thread_key LIKE ?", "#{THREAD_PREFIX}%")
                  .update_all(status: "received", claimed_by: nil, lease_expires_at: nil, attempts: 0)
      results = claim_in_parallel(%w[avi avi])
      assert_equal [ first.id ], results.compact, "only the thread's oldest message is handed out: #{results.inspect}"
    end
  end

  test "run in series: the second heartbeat finds nothing to pick up" do
    message = message!
    claimed = AgentMessage.claim!(soul: "avi", worker: "serial-1").message
    claimed.complete!(worker: "serial-1", response_text: "Answered.")

    assert_equal message.id, claimed.id
    assert_nil AgentMessage.claim!(soul: "avi", worker: "serial-2").message
  end

  test "two agents side by side: each picks up only its own message" do
    avi = message!(soul: "avi")
    alex = message!(soul: "alex")
    results = claim_in_parallel(%w[alex avi])

    assert_equal [ alex.id, avi.id ], results
  end
end
