require "test_helper"

# [unit] BuildIntake::PendingLaunch, the signed-out Build My App remembered across
# sign-in (task build-launch-sign-in): bound to one draft's token in one session,
# taken once, gone after an hour, and never handed out for another draft.
class BuildIntakePendingLaunchTest < ActiveSupport::TestCase
  Intent = BuildIntake::PendingLaunch

  setup do
    @session = {}
    @now = Time.zone.parse("2026-10-18 20:45")
  end

  test "bind then take returns the press once, with its address, and clears it" do
    Intent.bind(@session, token: "tok-abc", subdomain: "league-hub", now: @now)

    intent = Intent.take(@session, "tok-abc", now: @now + 5.minutes)
    assert_equal "tok-abc", intent.token
    assert_equal "league-hub", intent.subdomain
    assert_nil Intent.take(@session, "tok-abc", now: @now + 5.minutes), "single use: a refresh finds nothing"
    assert_not @session.key?(Intent::KEY)
  end

  test "an intent for another draft is not handed out and is left alone" do
    Intent.bind(@session, token: "tok-abc", subdomain: "league-hub", now: @now)

    assert_nil Intent.take(@session, "tok-other", now: @now)
    assert_equal "tok-abc", Intent.take(@session, "tok-abc", now: @now).token
  end

  test "an intent expires after an hour and taking a stale one still clears it" do
    Intent.bind(@session, token: "tok-abc", subdomain: nil, now: @now)
    assert_equal "tok-abc", Intent.pending_token(@session, now: @now + 59.minutes)

    assert_nil Intent.take(@session, "tok-abc", now: @now + Intent::TTL)
    assert_not @session.key?(Intent::KEY)
  end

  test "pending_token clears a stale intent and ignores an empty or malformed session" do
    assert_nil Intent.pending_token(@session, now: @now)
    @session[Intent::KEY] = "tok-abc"
    assert_nil Intent.pending_token(@session, now: @now), "not a hash"
    @session[Intent::KEY] = { "token" => "tok-abc", "at" => "yesterday" }
    assert_nil Intent.take(@session, "tok-abc", now: @now), "no integer time"

    Intent.bind(@session, token: "tok-abc", subdomain: "x", now: @now)
    assert_nil Intent.pending_token(@session, now: @now + 2.hours)
    assert_not @session.key?(Intent::KEY)
  end

  test "a time from the future is not fresh, and a blank address reads as none" do
    Intent.bind(@session, token: "tok-abc", subdomain: "", now: @now + 1.day)
    assert_nil Intent.pending_token(@session, now: @now)

    Intent.bind(@session, token: "tok-abc", subdomain: "", now: @now)
    assert_nil Intent.take(@session, "tok-abc", now: @now).subdomain
  end

  test "a session that stringified the keys (the cookie round trip) still reads" do
    Intent.bind(@session, token: "tok-abc", subdomain: "league-hub", now: @now)
    round_tripped = { Intent::KEY => JSON.parse(@session[Intent::KEY].to_json) }

    assert_equal "league-hub", Intent.take(round_tripped, "tok-abc", now: @now).subdomain
  end
end
