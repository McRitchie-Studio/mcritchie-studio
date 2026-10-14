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

  test "a release on the last attempt dead-letters: give-backs cannot loop past the cap" do
    message = agent_message!
    AgentMessage::MAX_ATTEMPTS.times do |i|
      AgentMessage.claim!(soul: "avi", worker: "w#{i}").message.release!(worker: "w#{i}", reason: "claude failed")
    end

    assert_equal "dead", message.reload.status
    assert_equal %w[released dead_lettered], message.events.last(2).map(&:kind)
    assert_nil AgentMessage.claim!(soul: "avi", worker: "late").message
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

  # --- renewal, the usage-limit refund, and the multi-soul claim (bin/dispatcher) ---

  test "the holder renews its lease by LEASE from now, and the timeline keeps one coalesced renewal event" do
    message = agent_message!
    start = Time.current
    AgentMessage.claim!(soul: "avi", worker: "w1", now: start)
    later = start + 3.minutes

    message.reload.renew!(worker: "w1", now: later)
    message.reload.renew!(worker: "w1", now: later + 3.minutes)

    message.reload
    assert_in_delta later + 3.minutes + AgentMessage::LEASE, message.lease_expires_at, 1
    renewals = message.events.select { |e| e.kind == "lease_renewed" }
    assert_equal 1, renewals.size, "renewals coalesce into one event per claim"
    assert_equal 2, renewals.first.detail["renewals"]
    assert_equal "w1", renewals.first.detail["worker"]
  end

  test "a renewal is refused to anyone but the holder, and to a holder whose lapsed lease was taken" do
    message = agent_message!
    start = Time.current
    AgentMessage.claim!(soul: "avi", worker: "w1", now: start)

    error = assert_raises(AgentMessage::Refused) { message.reload.renew!(worker: "w2") }
    assert_equal "NOT_HOLDER", error.code

    AgentMessage.claim!(soul: "avi", worker: "w2", now: start + AgentMessage::LEASE + 1.second)
    error = assert_raises(AgentMessage::Refused) { message.reload.renew!(worker: "w1") }
    assert_equal "NOT_HOLDER", error.code
    assert_equal "w2", message.reload.claimed_by
  end

  test "a holder whose lease lapsed but was not taken may still renew it" do
    message = agent_message!
    start = Time.current
    AgentMessage.claim!(soul: "avi", worker: "w1", now: start)

    message.reload.renew!(worker: "w1", now: start + AgentMessage::LEASE + 1.minute)

    assert message.reload.lease_live?(now: start + AgentMessage::LEASE + 2.minutes)
  end

  test "a usage_limit release hands the attempt back and never dead-letters, even on the last attempt" do
    message = agent_message!(attempts: AgentMessage::MAX_ATTEMPTS - 1)
    AgentMessage.claim!(soul: "avi", worker: "w1")
    assert_equal AgentMessage::MAX_ATTEMPTS, message.reload.attempts

    message.release!(worker: "w1", reason: "Claude usage limit", code: "usage_limit")

    message.reload
    assert_equal "received", message.status
    assert_equal AgentMessage::MAX_ATTEMPTS - 1, message.attempts
    released = message.events.last
    assert_equal "released", released.kind
    assert_equal "usage_limit", released.detail["code"]
    assert_equal true, released.detail["attempt_refunded"]
    refute message.events.any? { |e| e.kind == "dead_lettered" }
  end

  test "a plain release on the last attempt still dead-letters (the control for the refund)" do
    message = agent_message!(attempts: AgentMessage::MAX_ATTEMPTS - 1)
    AgentMessage.claim!(soul: "avi", worker: "w1")

    message.reload.release!(worker: "w1", reason: "Claude failed")

    assert_equal "dead", message.reload.status
  end

  test "an unknown release code is refused and changes nothing" do
    message = agent_message!
    AgentMessage.claim!(soul: "avi", worker: "w1")

    error = assert_raises(AgentMessage::Refused) { message.reload.release!(worker: "w1", code: "because") }
    assert_equal "UNKNOWN_CODE", error.code
    assert_equal "claimed", message.reload.status
    assert_equal 1, message.attempts
  end

  test "a multi-soul claim takes the oldest message across the souls, and records that message's soul" do
    xan = agent_message!(soul: "xan")
    agent_message!(soul: "avi")
    agent_message!(soul: "carl")

    first = AgentMessage.claim!(soul: %w[avi xan], worker: "d1").message
    second = AgentMessage.claim!(soul: %w[avi xan], worker: "d1").message
    third = AgentMessage.claim!(soul: %w[avi xan], worker: "d1").message

    assert_equal xan.id, first.id
    assert_equal "xan", first.events.find { |e| e.kind == "claimed" }.actor
    assert_equal "avi", second.soul_slug
    assert_nil third, "carl is not served"
  end

  test "a claim with an empty soul list is refused" do
    error = assert_raises(AgentMessage::Refused) { AgentMessage.claim!(soul: [ "", " " ], worker: "d1") }
    assert_equal "SOUL_REQUIRED", error.code
  end
end
