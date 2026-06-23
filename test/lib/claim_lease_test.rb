# frozen_string_literal: true

# Unit tests for the build-stage claim lease math (lib/claim_lease.rb). Pure
# functions — the clock and both instance identities are injected, so nothing
# shells out or reads the process tree. This is the unit tier for all four
# acceptance criteria; the bin/task gate + bin/statusline heartbeat get exercised
# end-to-end at the integration tier (test/lib/task_cli_test.rb, statusline_test.rb).
#
#   ruby -Itest test/lib/claim_lease_test.rb
# Also picked up by the normal `bin/rails test` sweep.

require "minitest/autorun"
require "time"
require_relative "../../lib/claim_lease"

class ClaimLeaseTest < Minitest::Test
  NOW = Time.utc(2026, 6, 23, 12, 0, 0)
  SESSION = "3751cb0d-9e1d-4260-ab96-20f5b00c0547"
  OTHER_SESSION = "aaaa1111-bbbb-2222-cccc-333344445555"

  def claim(session: SESSION, nonce: "inst-A", expires: NOW + 90)
    {
      "claimed_session"  => session,
      "claim_nonce"      => nonce,
      "claim_expires_at" => expires.is_a?(Time) ? expires.utc.iso8601 : expires
    }
  end

  # --- AC #1: building a claimed task warns UNLESS the lease has expired --------

  def test_live_claim_by_another_instance_is_held_by_other
    decision = ClaimLease.evaluate(claim(nonce: "inst-A"), session: SESSION, nonce: "inst-B", now: NOW)
    assert_equal :held_by_other, decision, "a live claim by a different instance must warn the mover"
  end

  def test_expired_claim_does_not_warn
    decision = ClaimLease.evaluate(claim(nonce: "inst-A", expires: NOW - 1), session: SESSION, nonce: "inst-B", now: NOW)
    assert_equal :expired, decision, "an expired lease is reclaimable — no warning"
  end

  # --- AC #2: the claim is keyed on session id PLUS a process nonce -------------

  def test_same_session_same_nonce_is_the_same_instance
    decision = ClaimLease.evaluate(claim(nonce: "inst-A"), session: SESSION, nonce: "inst-A", now: NOW)
    assert_equal :same_instance, decision, "session + nonce both match → this very instance re-moving"
  end

  def test_same_session_different_nonce_is_a_different_instance
    decision = ClaimLease.evaluate(claim(nonce: "inst-A"), session: SESSION, nonce: "inst-B", now: NOW)
    assert_equal :held_by_other, decision, "same session id, different nonce → a different live instance"
  end

  def test_different_session_is_a_different_instance
    decision = ClaimLease.evaluate(claim(session: OTHER_SESSION), session: SESSION, nonce: "inst-A", now: NOW)
    assert_equal :held_by_other, decision, "a different session holding a live claim must warn"
  end

  # --- AC #3: an expired OR dead-session lease is reclaimable automatically -----

  def test_unclaimed_is_reclaimable
    assert_equal :unclaimed, ClaimLease.evaluate({}, session: SESSION, nonce: "inst-A", now: NOW)
    assert_equal :unclaimed, ClaimLease.evaluate({ "claimed_session" => "" }, session: SESSION, nonce: "x", now: NOW)
  end

  def test_lease_past_expiry_is_reclaimable
    decision = ClaimLease.evaluate(claim(expires: NOW - 30), session: OTHER_SESSION, nonce: "inst-Z", now: NOW)
    assert_equal :expired, decision
  end

  def test_lease_with_no_or_garbled_expiry_fails_open_to_reclaimable
    # A dead session stops renewing → its lease lapses; a claim that somehow
    # carries no/garbled expiry must free the task, never lock it forever.
    assert_equal :expired, ClaimLease.evaluate(claim(expires: nil), session: OTHER_SESSION, nonce: "z", now: NOW)
    assert_equal :expired, ClaimLease.evaluate(claim(expires: "not-a-time"), session: OTHER_SESSION, nonce: "z", now: NOW)
  end

  def test_lease_exactly_at_now_is_expired
    decision = ClaimLease.evaluate(claim(expires: NOW), session: OTHER_SESSION, nonce: "z", now: NOW)
    assert_equal :expired, decision, "expiry boundary is inclusive — at-now counts as lapsed"
  end

  # --- AC #4: one session open in two terminals is DETECTED ---------------------

  def test_same_session_two_terminals_is_detected_as_distinct_live_instances
    # Terminal A claimed with nonce inst-A (its process). Terminal B is a
    # `claude --resume` of the SAME session id but a NEW process → nonce inst-B.
    # B asking to build must be detected as a second live instance, not waved through.
    held = claim(session: SESSION, nonce: "inst-A", expires: NOW + 60)
    decision = ClaimLease.evaluate(held, session: SESSION, nonce: "inst-B", now: NOW)
    assert_equal :held_by_other, decision
    refute_equal :same_instance, decision, "two terminals of one session must NOT look like the same instance"
  end

  # --- Graceful degrade: no nonce determinable on either side ------------------

  def test_session_only_claim_degrades_to_same_instance_for_the_same_session
    # When the nonce can't be resolved (empty on both sides), the claim degrades
    # to session-level: the same session is treated as the same instance (still
    # catches a DIFFERENT session), rather than locking the holder out of itself.
    held = claim(session: SESSION, nonce: "", expires: NOW + 60)
    assert_equal :same_instance, ClaimLease.evaluate(held, session: SESSION, nonce: "", now: NOW)
    assert_equal :held_by_other, ClaimLease.evaluate(held, session: OTHER_SESSION, nonce: "", now: NOW)
  end

  # --- live? + heartbeat_age + renewed -----------------------------------------

  def test_live_predicate
    assert ClaimLease.live?(claim(expires: NOW + 30), now: NOW)
    refute ClaimLease.live?(claim(expires: NOW - 30), now: NOW)
    refute ClaimLease.live?({}, now: NOW)
  end

  def test_heartbeat_age_is_derived_from_expiry_and_ttl
    # expiry = last_heartbeat + TTL ⇒ age = TTL - (expiry - now).
    age = ClaimLease.heartbeat_age(claim(expires: NOW + 90), now: NOW, ttl: 120)
    assert_equal 30, age, "120s TTL, lease has 90s left ⇒ last heartbeat 30s ago"
    assert_equal 0, ClaimLease.heartbeat_age(claim(expires: NOW + 200), now: NOW, ttl: 120), "never negative"
    assert_nil ClaimLease.heartbeat_age({}, now: NOW)
  end

  def test_renewed_writes_identity_and_a_fresh_lease
    fresh = ClaimLease.renewed(session: SESSION, nonce: "inst-A", now: NOW, ttl: 120)
    assert_equal SESSION, fresh["claimed_session"]
    assert_equal "inst-A", fresh["claim_nonce"]
    assert_equal (NOW + 120).utc.iso8601, fresh["claim_expires_at"]
    # A just-renewed claim reads back as this same live instance.
    assert_equal :same_instance, ClaimLease.evaluate(fresh, session: SESSION, nonce: "inst-A", now: NOW)
  end

  def test_from_devops_extracts_only_claim_keys
    devops = { "kind" => "feature", "claimed_session" => SESSION, "claim_nonce" => "n", "claim_expires_at" => "t" }
    assert_equal({ "claimed_session" => SESSION, "claim_nonce" => "n", "claim_expires_at" => "t" },
                 ClaimLease.from_devops(devops))
  end
end
