# frozen_string_literal: true

# The "at" format — the house primitive for stamping WHEN something happened.
#
# A relative stamp ("Shipped less than a minute ago") answers *how long ago* and
# then stops. It never tells the operator what the clock said, so it cannot be
# placed against the rest of a day. The "at" format answers the other question,
# and it answers it in the reader's own time:
#
#   · The clock is 12-hour with a single-letter meridiem — "3:53p" — the house
#     form already shared by the board footers (clock_12h) and the /deployments
#     range cells (deployment_clock).
#   · The date appears ONLY when the stamp is not today. A release that shipped
#     minutes ago needs no date; one from last week is ambiguous without it. The
#     year joins only when it differs, so "Aug 10, 3:53p" stays short all year.
#   · A country flag TRAILS the clock when the reader's timezone sits outside the
#     US. Inside the US there is no flag at all — the flag carries signal only
#     because it is unusual, and one that fired on every stamp would carry none.
#   · The relative phrase is not thrown away; it moves to the hover title, beside
#     the full local stamp and its zone name.
#
# WHO OWNS WHAT. The server renders the app-timezone form as the pre-hydration
# and no-JS fallback, and never renders a flag — it cannot know where the reader
# is sitting. `shared/_at_time_script` re-stamps the clock to the VIEWER's local
# time and adds the flag from the browser's IANA zone. That split is the whole
# design: the flag is a fact about the reader, so only the reader's machine may
# assert it.
#
# This is a primitive, not a release-card detail — `release_state_label` is only
# its first caller. Keep it free of any one caller's vocabulary; it is staged
# here to be lifted into studio-engine as a shared Studio helper.
module AtTimeHelper
  MONTH_DAY = "%b %-d"

  # "3:53p" / "11:07a" — 12-hour clock, no leading zero, single-letter meridiem,
  # no space. Zones the time into the app zone first, so a bare UTC timestamp and
  # an already-zoned one render the same. nil-safe.
  def at_clock(time)
    return nil if time.blank?

    local = time.in_time_zone
    "#{local.strftime('%-l:%M')}#{local.hour < 12 ? 'a' : 'p'}"
  end

  # The date half of an "at" stamp, or nil when the stamp falls on `now`'s date —
  # today's stamps carry no date. "Aug 10" within the current year, "Aug 10 2025"
  # outside it. `now` is injectable so the boundary is testable.
  def at_date(time, now: Time.current)
    return nil if time.blank?

    local = time.in_time_zone
    today = now.in_time_zone
    return nil if local.to_date == today.to_date

    return local.strftime(MONTH_DAY) if local.year == today.year

    "#{local.strftime(MONTH_DAY)} #{local.year}"
  end

  # The visible text of an "at" stamp: "3:53p" today, "Aug 10, 3:53p" otherwise.
  # The JS half builds the identical string from the viewer's clock — change one
  # and change the other, or the value flickers on hydration.
  def at_stamp_text(time, now: Time.current)
    return nil if time.blank?

    date = at_date(time, now: now)
    date ? "#{date}, #{at_clock(time)}" : at_clock(time)
  end

  # The hover title: the relative phrase this format replaced, then the full local
  # stamp with its zone. Server-side that zone is the app's; the script rewrites
  # the whole title in the viewer's.
  def at_stamp_title(time)
    return nil if time.blank?

    local = time.in_time_zone
    "#{time_ago_in_words(local)} ago · #{local.strftime('%a, %b %-d, %Y, %-l:%M %p %Z')}"
  end

  # The primitive itself. Renders a <time> carrying the epoch the script re-stamps
  # from, the text slot, and the (server-side empty) flag slot that trails it.
  #
  #   at_time_tag(release.shipped_at)              => "at 3:53p"
  #   at_time_tag(task.created_at, prefix: nil)    => "3:53p"
  #
  # nil for a blank time, so a caller can `<%= at_time_tag(t) %>` unguarded.
  def at_time_tag(time, prefix: "at", now: Time.current, css_class: nil)
    return nil if time.blank?

    local = time.in_time_zone
    text = at_stamp_text(local, now: now)
    text = "#{prefix} #{text}" if prefix.present?

    tag.time(datetime: local.iso8601,
             title: at_stamp_title(local),
             class: ["whitespace-nowrap", css_class].compact.join(" "),
             data: { at_stamp: "", at_epoch: local.to_i, at_prefix: prefix.to_s }) do
      # No whitespace between the two slots: the gap is `ml-2` on the flag, which
      # collapses with the flag itself when the reader is inside the US.
      safe_join([
        tag.span(text, data: { at_text: "" }),
        tag.span("", class: "ml-2", hidden: true, data: { at_flag: "" })
      ])
    end
  end
end
