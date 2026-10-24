require "test_helper"

# [unit] The allowance month resets at 1:00 America/Denver on the 1st, and the
# chat meter says so (task cto-chat-quality-pass, Alex 2026-10-19: "42% used ·
# Resets Nov 1 at 1am MST"; under a fifth left, "Resets in 3d 4h").
class AgentUsageResetTest < ActiveSupport::TestCase
  ZONE = ActiveSupport::TimeZone["America/Denver"]

  def range_at(utc) = AgentUsage.month_range(Time.utc(*utc))

  def meter(used:, allowance: 25_000, now: Time.utc(2026, 10, 20, 4, 50))
    start, finish = AgentUsage.month_range(now)
    AgentUsage::Meter.new(app_slug: "pawsome", allowance: allowance, used: used, public_used: 0,
                          totals: AgentUsage::Totals.zero, capped_count: 0, period_start: start, period_end: finish,
                          now: now, warn_percent: 80)
  end

  test "[unit] the month runs from 1am Denver on the 1st to 1am on the next 1st" do
    start, finish = range_at([ 2026, 10, 20, 4, 50 ])
    assert_equal ZONE.local(2026, 10, 1, 1), start, "1am MDT on Oct 1"
    assert_equal Time.utc(2026, 11, 1, 8), finish.utc, "Nov 1 2026 is the fall-back Sunday: the reset is 1am MST, 08:00 UTC"
    assert_equal "MST", finish.strftime("%Z")
  end

  test "[unit] the hour after Denver midnight on the 1st still belongs to the month before" do
    assert_equal ZONE.local(2026, 10, 1, 1), range_at([ 2026, 11, 1, 6, 30 ]).first, "00:30 MDT Nov 1 is October"
    assert_equal ZONE.local(2026, 10, 1, 1), range_at([ 2026, 11, 1, 7, 30 ]).first, "the first 1:30 (MDT) is still October"
    start, = range_at([ 2026, 11, 1, 8, 0 ])
    assert_equal Time.utc(2026, 11, 1, 8), start.utc, "1am MST opens November"
  end

  test "[unit] the year rolls over at 1am Denver on Jan 1" do
    start, finish = range_at([ 2027, 1, 1, 7, 59 ]) # 00:59 MST Jan 1
    assert_equal ZONE.local(2026, 12, 1, 1), start
    assert_equal ZONE.local(2027, 1, 1, 1), finish
    start, finish = range_at([ 2027, 1, 1, 8, 0 ])
    assert_equal ZONE.local(2027, 1, 1, 1), start
    assert_equal ZONE.local(2027, 2, 1, 1), finish
  end

  test "[unit] across spring forward the reset stays at 1am, in daylight time from April" do
    start, finish = range_at([ 2027, 3, 20, 12, 0 ])
    assert_equal [ "MST", "MDT" ], [ start.strftime("%Z"), finish.strftime("%Z") ]
    assert_equal [ 1, 1 ], [ start.hour, finish.hour ]
    assert_equal "Resets Apr 1 at 1am MDT", meter(used: 0, now: Time.utc(2027, 3, 20, 12)).resets_line
  end

  test "[unit] the meter reads the percent used and the reset line" do
    m = meter(used: 10_689)
    assert_equal 42, m.percent
    assert_equal "Resets Nov 1 at 1am MST", m.resets_line
    assert_equal "Nov 1", m.resets_on
    assert_not m.countdown?, "58% left: the right side shows tokens"
  end

  test "[unit] under a fifth left (the warn share) or at the cap, the meter counts down" do
    assert_not meter(used: 19_999).countdown?, "79%"
    assert meter(used: 20_000).countdown?, "80%: under 20% left"
    assert meter(used: 25_000).countdown?, "capped"
    assert_not meter(used: 0, allowance: nil).countdown?, "unlimited never counts down"
  end

  test "[unit] the countdown reads days and hours, then hours and minutes, then minutes" do
    m = meter(used: 21_000, now: Time.utc(2026, 10, 29, 4, 0))
    assert_equal "Resets in 3d 4h", m.countdown_line(m.now)
    assert_equal "Resets in 4h 12m", AgentUsage.countdown_line((4 * 3600) + (12 * 60))
    assert_equal "Resets in 12m", AgentUsage.countdown_line(11 * 60 + 1), "minutes round up"
    assert_equal "Resets in 1m", AgentUsage.countdown_line(1)
    assert_equal "Resets in 1d 0h", AgentUsage.countdown_line(24 * 3600)
    assert_equal "Resetting now", AgentUsage.countdown_line(0)
  end

  test "[unit] Nov 1 2026, the fall-back Sunday: 1am happens twice and the month turns at the second, 1am MST" do
    first_one_am = Time.utc(2026, 11, 1, 7, 0)  # 01:00 MDT
    second_one_am = Time.utc(2026, 11, 1, 8, 0) # 01:00 MST
    assert_equal "MDT", first_one_am.in_time_zone(ZONE).strftime("%Z")
    assert_equal 10, AgentUsage.month_range(first_one_am).first.month, "the first 1am is still October"
    assert_equal 10, AgentUsage.month_range(second_one_am - 1).first.month
    start, finish = AgentUsage.month_range(second_one_am)
    assert_equal [ second_one_am, "MST" ], [ start.utc, start.strftime("%Z") ]
    assert_equal ZONE.local(2026, 12, 1, 1), finish
    assert_equal 30.days.to_i, (finish - start).to_i, "1am MST to 1am MST: exactly 30 days"
  end

  test "[unit] the cap reply names the same reset moment the meter does" do
    m = meter(used: 25_000)
    assert_includes AgentUsage.cap_reply(m), "It resets Nov 1 at 1am MST."
    assert_equal "I can't answer right now. Please try again after Nov 1 at 1am MST.", AgentUsage.cap_reply(m, audience: "public")
  end

  test "[unit] counting down, the meter says Resets once: the left line drops, the countdown carries it as a title" do
    html = ApplicationController.render(partial: "agent_chats/tokens_bar", locals: { meter: meter(used: 21_000) })
    assert_equal 1, html.scan(/Resets in/).size
    assert_no_match(/data-test="usage-meter-resets"/, html)
    assert_match(/data-test="usage-meter-countdown"[^>]*title="Resets Nov 1 at 1am MST"/m, html)
    calm = ApplicationController.render(partial: "agent_chats/tokens_bar", locals: { meter: meter(used: 10_689) })
    assert_match(/data-test="usage-meter-resets">Resets Nov 1 at 1am MST</, calm)
    assert_match(/data-test="usage-meter-tokens">10,689 \/ 25,000</, calm)
  end
end
