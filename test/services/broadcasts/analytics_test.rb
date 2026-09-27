require "test_helper"

# [unit] The dashboard's numbers: each counts what its label says.
class Broadcasts::AnalyticsTest < ActiveSupport::TestCase
  setup do
    @broadcast = Broadcast.create!(subject: "Cyvasse is back", template_key: "cyvasse_is_back")
    @other = Broadcast.create!(subject: "Kickoff", template_key: "world_cup_kickoff")
  end

  def deliver(email, broadcast: @broadcast, sent_at: Time.utc(2026, 9, 28, 16))
    broadcast.deliveries.create!(contact: Contact.create!(email: email), sent_at: sent_at)
  end

  test "the summary counts sends, deliveries, bounces, complaints and people" do
    a = deliver("a@gmail.com")
    b = deliver("b@hotmail.com")
    c = deliver("c@example.org")
    deliver("d@gmail.com")
    [a, b, c].each { |d| d.record_event!(kind: "delivered", source: "resend") }
    c.record_event!(kind: "bounced", source: "resend", data: { "bounce_kind" => "hard" })
    b.record_event!(kind: "complained", source: "resend")
    a.record_open!                                  # a person
    b.record_open!(machine: true)                   # Apple's prefetch only
    a.record_click!(link_key: "play")
    a.record_open!(source: "resend")                # never counted

    s = Broadcasts::Analytics.new(broadcast: @broadcast).summary
    assert_equal [4, 3, 1, 0, 1], [s.sent, s.delivered, s.hard_bounced, s.soft_bounced, s.complained]
    assert_equal [1, 1, 1, 0], [s.human_opened, s.machine_only_opened, s.human_clicked, s.machine_only_clicked]
    assert_in_delta 0.25, s.bounce_rate
    assert_in_delta 1.0 / 3, s.complaint_rate, 1e-9, "complaints over delivered once Resend reports deliveries"
    assert_in_delta 1.0 / 3, s.open_rate, 1e-9
  end

  test "before any delivery report, rates use the emails sent" do
    deliver("a@gmail.com").record_open!
    deliver("b@gmail.com")
    assert_in_delta 0.5, Broadcasts::Analytics.new.summary.open_rate
  end

  test "a result counts each email once per goal" do
    a = deliver("a@gmail.com")
    3.times { |i| a.record_event!(kind: "converted", source: "beacon", data: { "goal" => "played_match" }, provider_event_id: "g#{i}") }
    deliver("b@gmail.com").record_event!(kind: "converted", source: "beacon", data: { "goal" => "played_match" })

    assert_equal 2, Broadcasts::Analytics.new.summary.results["played_match"]
    assert_equal 0, Broadcasts::Analytics.new.summary.results["signed_in"]
  end

  test "mailbox providers group by the address's domain, biggest first" do
    deliver("a@gmail.com"); deliver("b@GoogleMail.com"); deliver("c@hotmail.com"); deliver("d@proton.me")
    by = Broadcasts::Analytics.new.by_provider.to_h { |name, s| [name, s.sent] }
    assert_equal({ "Gmail" => 2, "Microsoft" => 1, "Other" => 1 }, by)
    assert_equal "Gmail", Broadcasts::Analytics.new.by_provider.first.first
  end

  test "one email's numbers leave the others out, and a send day groups its sends" do
    deliver("a@gmail.com")
    deliver("b@gmail.com", broadcast: @other, sent_at: Time.utc(2026, 9, 29, 1))
    assert_equal 1, Broadcasts::Analytics.new(broadcast: @broadcast).summary.sent
    days = Broadcasts::Analytics.new.by_send_day.map { |day, s| [day.to_s, s.sent] }
    assert_equal [["2026-09-29", 1], ["2026-09-28", 1]], days
  end

  test "clicks by link split people from programs" do
    a = deliver("a@gmail.com")
    b = deliver("b@gmail.com")
    a.record_click!(link_key: "play")
    b.record_click!(link_key: "play", machine: true)
    a.record_click!(link_key: "build")
    assert_equal [["play", 1, 1], ["build", 1, 0]], Broadcasts::Analytics.new.by_link
  end

  test "health turns amber and red at Resend's lines" do
    limits = Broadcasts::Analytics::BOUNCE
    assert_equal :none, Broadcasts::Analytics.health(nil, limits)
    assert_equal :green, Broadcasts::Analytics.health(0.01, limits)
    assert_equal :amber, Broadcasts::Analytics.health(0.03, limits)
    assert_equal :red, Broadcasts::Analytics.health(0.04, limits)
  end

  # The grouped tables are the per-row summary, computed in bulk.
  test "every grouped row equals the summary of its own deliveries" do
    a = deliver("a@gmail.com")
    b = deliver("b@hotmail.com", broadcast: @other, sent_at: Time.utc(2026, 9, 29, 1))
    c = deliver("c@proton.me", sent_at: Time.utc(2026, 9, 29, 2))
    [a, b, c].each { |d| d.record_event!(kind: "delivered", source: "resend") }
    a.record_open!
    b.record_click!(link_key: "play")
    c.record_event!(kind: "bounced", source: "resend", data: { "bounce_kind" => "hard" })
    a.record_event!(kind: "converted", source: "beacon", data: { "goal" => "signed_in" })
    c.record_event!(kind: "converted", source: "beacon", data: { "goal" => "played_match" })
    analytics = Broadcasts::Analytics.new

    analytics.by_broadcast.each do |broadcast, sum|
      assert_equal analytics.summary(analytics.deliveries.where(broadcast: broadcast)), sum, broadcast.subject
    end
    analytics.by_send_day.each do |day, sum|
      assert_equal analytics.summary(analytics.deliveries.where(sent_at: Time.utc(day.year, day.month, day.day).all_day)), sum, day.to_s
    end
    gmail = analytics.by_provider.to_h["Gmail"]
    assert_equal analytics.summary(analytics.deliveries.where(id: a.id)), gmail
  end

  test "a breakdown costs the same queries for one group as for many" do
    deliver("a@gmail.com")
    one = sql_count { Broadcasts::Analytics.new.by_send_day }
    deliver("b@gmail.com", sent_at: Time.utc(2026, 9, 29, 1))
    deliver("c@gmail.com", sent_at: Time.utc(2026, 9, 30, 1))
    assert_equal one, sql_count { Broadcasts::Analytics.new.by_send_day }
  end

  private

  def sql_count(&block)
    count = 0
    counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:sql].start_with?("SAVEPOINT", "RELEASE") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
    count
  end
end
