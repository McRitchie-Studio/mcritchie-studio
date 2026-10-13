require "test_helper"
require_relative "../support/agent_message_fixtures"

# [unit] AgentMessage — the lease state machine on one connection: claim, the
# soul filter, per-thread order, lease expiry and the attempt cap, dead letter,
# the complete-once guard and release. The two-connection race is
# test/integration/agent_message_claim_race_test.rb.
class AgentMessageTest < ActiveSupport::TestCase
  include AgentMessageFixtures
  include ActiveJob::TestHelper

  test "a claim takes the oldest waiting message for the soul and stamps a lease" do
    older = agent_message!
    agent_message!
    now = Time.current

    result = AgentMessage.claim!(soul: "avi", worker: "w1", now: now)

    assert_equal older.id, result.message.id
    assert_equal "claimed", result.message.status
    assert_equal "w1", result.message.claimed_by
    assert_equal 1, result.message.attempts
    assert_in_delta now + AgentMessage::LEASE, result.message.lease_expires_at, 1
    assert_equal %w[claimed], older.reload.events.map(&:kind)
  end

  test "a serial second claim gets the next message, then nothing" do
    agent_message!
    assert AgentMessage.claim!(soul: "avi", worker: "w1").message
    result = AgentMessage.claim!(soul: "avi", worker: "w2")
    assert_nil result.message
    assert_equal "nothing_waiting", result.reason
  end

  test "a soul never receives another soul's message, and unrouted is never handed out" do
    agent_message!(soul: "avi")
    agent_message!(soul: nil, status: "unrouted", routed_by: "none")

    assert_nil AgentMessage.claim!(soul: "xan", worker: "x1").message
    assert_equal "avi", AgentMessage.claim!(soul: "avi", worker: "a1").message.soul_slug
    assert_nil AgentMessage.claim!(soul: "avi", worker: "a2").message
  end

  test "a completed message is never claimed again" do
    message = agent_message!
    AgentMessage.claim!(soul: "avi", worker: "w1")
    message.reload.complete!(worker: "w1", response_text: "done")

    assert_nil AgentMessage.claim!(soul: "avi", worker: "w2", now: 1.day.from_now).message
  end

  test "one thread is answered in order: its newer message waits while an older one is open" do
    first = agent_message!(thread_key: "discord:t:1")
    second = agent_message!(thread_key: "discord:t:1")
    other = agent_message!(thread_key: "discord:t:2")

    assert_equal first.id, AgentMessage.claim!(soul: "avi", worker: "w1").message.id
    assert_equal other.id, AgentMessage.claim!(soul: "avi", worker: "w2").message.id,
                 "the thread's second message is held back while its first is claimed"
    assert_nil AgentMessage.claim!(soul: "avi", worker: "w3").message

    first.reload.complete!(worker: "w1", response_text: "ok")
    assert_equal second.id, AgentMessage.claim!(soul: "avi", worker: "w3").message.id
  end

  test "an expired lease is reclaimable, counts the attempt, and records the lapse" do
    message = agent_message!
    t0 = Time.current
    AgentMessage.claim!(soul: "avi", worker: "w1", now: t0)

    assert_nil AgentMessage.claim!(soul: "avi", worker: "w2", now: t0 + 5.minutes).message, "a live lease holds"
    result = AgentMessage.claim!(soul: "avi", worker: "w2", now: t0 + AgentMessage::LEASE + 1.second)

    assert_equal message.id, result.message.id
    assert_equal "w2", result.message.claimed_by
    assert_equal 2, result.message.attempts
    assert_equal %w[claimed lease_expired claimed], message.reload.events.map(&:kind)
  end

  test "the attempt cap dead-letters a message whose last lease lapsed" do
    message = agent_message!
    t = Time.current
    AgentMessage::MAX_ATTEMPTS.times do |i|
      assert AgentMessage.claim!(soul: "avi", worker: "w#{i}", now: t).message, "attempt #{i + 1} is handed out"
      t += AgentMessage::LEASE + 1.second
    end

    assert_nil AgentMessage.claim!(soul: "avi", worker: "late", now: t).message
    assert_equal "dead", message.reload.status
    assert_equal "dead_lettered", message.events.last.kind
    assert_equal AgentMessage::MAX_ATTEMPTS, message.attempts
  end

  test "a dead message no longer holds its thread back" do
    stuck = agent_message!(thread_key: "discord:t:9", status: "dead")
    behind = agent_message!(thread_key: "discord:t:9")
    assert stuck
    assert_equal behind.id, AgentMessage.claim!(soul: "avi", worker: "w").message.id
  end

  test "complete twice by the holder records once and queues one reply" do
    message = agent_message!
    AgentMessage.claim!(soul: "avi", worker: "w1")
    message.reload

    assert_enqueued_jobs 1, only: AgentMessageReplyJob do
      assert_equal :completed, message.complete!(worker: "w1", response_text: "Release is green.", action_summary: "ran bin/release status")
      assert_equal :already_completed, message.complete!(worker: "w1", response_text: "Release is green.")
    end
    message.reload
    assert_equal "completed", message.status
    assert_equal "agentmsg-#{message.id}", message.reply_nonce
    assert_nil message.lease_expires_at
    assert_equal 1, message.events.where(kind: "completed").count
  end

  test "only the holder completes or releases" do
    message = agent_message!
    AgentMessage.claim!(soul: "avi", worker: "w1")
    message.reload

    error = assert_raises(AgentMessage::Refused) { message.complete!(worker: "w2", response_text: "x") }
    assert_equal "NOT_HOLDER", error.code
    assert_raises(AgentMessage::Refused) { message.complete!(worker: "", response_text: "x") }
    assert_raises(AgentMessage::Refused) { message.release!(worker: "w2") }
    assert_equal "claimed", message.reload.status
  end

  test "an unclaimed message cannot be completed, and an empty answer is refused" do
    message = agent_message!
    assert_raises(AgentMessage::Refused) { message.complete!(worker: "w1", response_text: "x") }
    AgentMessage.claim!(soul: "avi", worker: "w1")
    error = assert_raises(AgentMessage::Refused) { message.reload.complete!(worker: "w1", response_text: " ") }
    assert_equal "RESPONSE_REQUIRED", error.code
  end

  test "release returns the message to the queue and keeps the attempt it used" do
    message = agent_message!
    AgentMessage.claim!(soul: "avi", worker: "w1")
    message.reload.release!(worker: "w1", reason: "gave up")

    message.reload
    assert_equal "received", message.status
    assert_nil message.claimed_by
    assert_equal 1, message.attempts
    assert_equal "gave up", message.events.last.detail["reason"]
    assert_equal 2, AgentMessage.claim!(soul: "avi", worker: "w2").message.attempts
  end

  test "a claim needs a worker and a soul" do
    assert_equal "WORKER_REQUIRED", assert_raises(AgentMessage::Refused) { AgentMessage.claim!(soul: "avi", worker: " ") }.code
    assert_equal "SOUL_REQUIRED", assert_raises(AgentMessage::Refused) { AgentMessage.claim!(soul: "", worker: "w") }.code
  end

  test "a routed message needs a soul; the external id is unique per channel" do
    refute AgentMessage.new(channel: "discord", external_id: "1", channel_ref: "c", thread_key: "t", status: "received").valid?
    message = agent_message!
    dup = message.dup
    refute dup.valid?
    assert_includes dup.errors[:external_id], "has already been taken"
  end

  test "the database refuses a status or reply status outside the lists, even past validations" do
    message = agent_message!
    assert_raises(ActiveRecord::CheckViolation) do
      AgentMessage.transaction(requires_new: true) { AgentMessage.where(id: message.id).update_all(status: "limbo") }
    end
    assert_raises(ActiveRecord::CheckViolation) do
      AgentMessage.transaction(requires_new: true) { AgentMessage.where(id: message.id).update_all(reply_status: "maybe") }
    end
    assert_equal 1, AgentMessage.where(id: message.id).update_all(status: "dead", reply_status: nil)
  end

  test "the Discord links name the guild, channel and message" do
    message = agent_message!(reply_external_id: "123")
    assert_equal "https://discord.com/channels/#{GUILD}/#{DESK}/#{message.external_id}", message.discord_url
    assert_equal "https://discord.com/channels/#{GUILD}/#{DESK}/123", message.reply_url
  end
end
