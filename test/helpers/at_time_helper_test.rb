require "test_helper"

# The "at" format primitive. These pin the SERVER half — the clock shape, when
# the date joins it, and the markup contract the client half re-stamps through
# (shared/_at_time_script). The flag itself is deliberately absent from every
# assertion here: the server cannot know the reader's timezone, so it must never
# assert one.
#
# The flag half is covered in a real browser by e2e/at_time_flag.spec.js, which
# drives the installed script across US and non-US zones. The two halves meet at
# the markup contract asserted below — the epoch, the text slot, and the hidden
# ml-2 flag slot — so a change here needs the matching change there.
class AtTimeHelperTest < ActionView::TestCase
  # A fixed "now" in the app zone; every case below is positioned against it, so
  # the today/not-today boundary is tested rather than whatever day CI runs on.
  NOW = Time.utc(2026, 8, 11, 20, 0, 0)

  test "at_clock renders a 12-hour clock with a single-letter meridiem" do
    assert_equal "3:53p", at_clock(Time.utc(2026, 8, 11, 15, 53, 0))
    assert_equal "11:07a", at_clock(Time.utc(2026, 8, 11, 11, 7, 0))
  end

  test "at_clock names the meridiem boundaries as 12, never 0" do
    assert_equal "12:00a", at_clock(Time.utc(2026, 8, 11, 0, 0, 0)), "midnight is 12a, not 0a"
    assert_equal "12:30p", at_clock(Time.utc(2026, 8, 11, 12, 30, 0)), "noon is 12p, not 0p"
    assert_equal "11:59a", at_clock(Time.utc(2026, 8, 11, 11, 59, 0)), "the last minute before noon is still am"
  end

  test "at_clock is nil-safe" do
    assert_nil at_clock(nil)
    assert_nil at_clock("")
  end

  test "at_date is nil for today, dates another day, and adds the year only when it differs" do
    assert_nil at_date(NOW - 3.hours, now: NOW), "a stamp from today carries no date"
    assert_equal "Aug 10", at_date(Time.utc(2026, 8, 10, 15, 53, 0), now: NOW)
    assert_equal "Aug 10 2025", at_date(Time.utc(2025, 8, 10, 15, 53, 0), now: NOW)
  end

  test "at_date turns over at the calendar boundary, not at 24 hours elapsed" do
    just_before_midnight = Time.utc(2026, 8, 10, 23, 59, 0)
    assert_equal "Aug 10", at_date(just_before_midnight, now: NOW),
                 "20 hours ago but yesterday's date — the date is what disambiguates it"
  end

  test "at_stamp_text is the clock alone today and date-prefixed otherwise" do
    assert_equal "3:53p", at_stamp_text(Time.utc(2026, 8, 11, 15, 53, 0), now: NOW)
    assert_equal "Aug 10, 3:53p", at_stamp_text(Time.utc(2026, 8, 10, 15, 53, 0), now: NOW)
    assert_nil at_stamp_text(nil, now: NOW)
  end

  test "at_time_tag renders the epoch the client re-stamps from" do
    time = Time.utc(2026, 8, 11, 15, 53, 0)
    node = Nokogiri::HTML.fragment(at_time_tag(time, now: NOW)).at_css("time")

    assert_equal time.to_i.to_s, node["data-at-epoch"],
                 "the epoch is the client's only input — without it the stamp cannot be localized"
    assert_equal time.utc.iso8601, node["datetime"]
    assert node.key?("data-at-stamp"), "the script selects on [data-at-stamp]"
  end

  test "at_time_tag prefixes the stamp with 'at' by default and honors an explicit prefix" do
    time = Time.utc(2026, 8, 11, 15, 53, 0)

    assert_equal "at 3:53p", at_stamp_slot_text(at_time_tag(time, now: NOW))
    assert_equal "3:53p", at_stamp_slot_text(at_time_tag(time, prefix: nil, now: NOW))
    assert_equal "at", Nokogiri::HTML.fragment(at_time_tag(time, now: NOW)).at_css("time")["data-at-prefix"],
                 "the client rebuilds the label, so it needs the prefix as data"
  end

  test "at_time_tag renders an empty, hidden flag slot" do
    node = Nokogiri::HTML.fragment(at_time_tag(Time.utc(2026, 8, 11, 15, 53, 0), now: NOW))
    flag = node.at_css("[data-at-flag]")

    assert flag, "the flag slot must exist server-side for the client to fill"
    assert_equal "", flag.text, "the server never asserts a country — it cannot know the reader's"
    assert flag.key?("hidden"), "an empty slot must not reserve its margin"
    assert_includes flag["class"], "ml-2", "the flag sits to the RIGHT of the clock, with space"
  end

  test "at_time_tag keeps the relative phrase in the hover title" do
    node = Nokogiri::HTML.fragment(at_time_tag(7.minutes.ago, now: Time.current)).at_css("time")
    assert_match(/7 minutes ago ·/, node["title"],
                 "the relative read this format replaced is demoted, not deleted")
  end

  test "at_time_tag folds every spelling of 'no prefix' to the same thing on both halves" do
    time = Time.utc(2026, 8, 11, 15, 53, 0)

    [nil, "", false].each do |blank|
      node = Nokogiri::HTML.fragment(at_time_tag(time, prefix: blank, now: NOW)).at_css("time")

      assert_equal "3:53p", node.at_css("[data-at-text]").text, "prefix #{blank.inspect} renders bare"
      # The client REBUILDS the label from this attribute, so a stringified value
      # here hydrates to a visible "false 3:53p" the server never showed.
      refute node.key?("data-at-prefix"),
             "prefix #{blank.inspect} must omit the attribute, not stringify it"
    end
  end

  test "at_time_tag measures the hover title against the injected now, not the wall clock" do
    time = Time.utc(2026, 8, 11, 15, 53, 0) # 4h 7m before NOW
    node = Nokogiri::HTML.fragment(at_time_tag(time, now: NOW)).at_css("time")

    assert_match(/\Aabout 4 hours ago ·/, node["title"],
                 "an injected now must reach the title too, or it describes a different moment " \
                 "than the label beside it")
  end

  test "at_time_tag is nil for a blank time so callers need no guard" do
    assert_nil at_time_tag(nil)
    assert_nil at_time_tag("")
  end

  private

  # The visible text slot only — excludes the flag span, which is empty server-side.
  def at_stamp_slot_text(html)
    Nokogiri::HTML.fragment(html).at_css("[data-at-text]").text
  end
end
