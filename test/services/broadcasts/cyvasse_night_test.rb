require "test_helper"

# [unit] The Cyvasse Night invite (task cyvasse-night-invite-email): the
# subject a reader gets with and without a username, the body with and
# without Cyvasse stats, and that every link in it goes through the hub's
# click tracker, never straight to cyvasse.xyz.
class Broadcasts::CyvasseNightTest < ActionDispatch::IntegrationTest
  PLAIN = "Cyvasse Night is Tuesday at 7 PM Mountain".freeze

  setup do
    @broadcast = Broadcast.create!(slug: "cyvasse-night-unit", template_key: "cyvasse_night", subject: PLAIN)
    @contact = Contact.create!(email: "ann@example.com")
  end

  def render_mail(fields)
    mail = BroadcastMailer.campaign(@broadcast, @contact, BroadcastDelivery.new(token: "tok-night"), merge_fields: fields).message
    [ mail.subject, mail.html_part ? mail.html_part.decoded : mail.decoded ]
  end

  def text(html) = Nokogiri::HTML5(html).text.squish

  test "with a username the subject is personal" do
    assert_equal "Ann, Cyvasse Night is Tuesday at 7 PM Mountain", @broadcast.subject_for("username" => "Ann")
  end

  test "without a username the subject is the plain line" do
    assert_equal PLAIN, @broadcast.subject_for({})
    assert_equal PLAIN, @broadcast.subject_for("email" => "ann@example.com", "username" => "")
  end

  test "the subject has no emoji, no shouting and no exclamation" do
    [ @broadcast.subject_for("username" => "Ann"), @broadcast.subject_for({}) ].each do |line|
      assert line.ascii_only?, "no emoji: #{line}"
      assert_not_includes line, "!"
      assert_no_match(/\b[A-Z]{3,}\b/, line.gsub(/\b(PM)\b/, ""), "no ALL CAPS words")
    end
  end

  test "it requires no merge fields, so a reader without stats is never skipped" do
    assert_empty @broadcast.required_merge_fields
    assert_not @broadcast.requires_staging?
  end

  test "the calendar, night and play links resolve to their destinations" do
    assert_equal "https://cyvasse.xyz/night.ics", @broadcast.link_for("calendar")
    assert_equal "https://cyvasse.xyz/night", @broadcast.link_for("night")
    assert_equal "https://cyvasse.xyz/", @broadcast.link_for("play")
    assert_equal "https://mcritchie.studio/build", @broadcast.link_for("build")
    assert_includes @broadcast.link_keys, "calendar"
  end

  test "the body with stats greets by name and adds the experience line" do
    subject, html = render_mail({ "username" => "<Ann>", "games" => 42, "wins" => 30 })

    assert_equal "<Ann>, Cyvasse Night is Tuesday at 7 PM Mountain", subject
    body = text(html)
    assert_includes html, "Hi &lt;Ann&gt;,", "the username is escaped"
    assert_includes body, "On Tuesday, October 6, at 7 PM Mountain (that’s 9 PM Eastern / 6 PM Pacific), " \
                          "we’re holding Cyvasse Night: one night when everyone plays live at once."
    assert_includes body, "Open Cyvasse, hit Play Now, and you’re matched with a real player, not the computer. " \
                          "Wins count toward the night’s leaderboard."
    assert_includes body, "Bring your 30 wins’ worth of experience."
    assert_includes body, "See Cyvasse Night"
    assert_includes body, "Add it to your calendar"
    assert_includes body, "— Alex"
    assert_includes body, "we’ll build it"
  end

  test "the experience line pluralizes, and falls back to games when there are no wins" do
    assert_equal "Bring your 1 win’s worth of experience.", Broadcasts::CyvasseNight.experience_line("wins" => 1)
    assert_equal "Bring your 7 games’ worth of experience.", Broadcasts::CyvasseNight.experience_line("wins" => 0, "games" => 7)
    assert_equal "Bring your 1 game’s worth of experience.", Broadcasts::CyvasseNight.experience_line("games" => "1")
    assert_nil Broadcasts::CyvasseNight.experience_line("username" => "Ann")
    assert_nil Broadcasts::CyvasseNight.experience_line(nil)
  end

  test "the body without stats renders plainly: no name, no experience line, no braces" do
    subject, html = render_mail({ "email" => "ann@example.com" })

    assert_equal PLAIN, subject
    body = text(html)
    assert_includes body, "Hi there,"
    assert_includes body, "one night when everyone plays live at once"
    assert_not_includes body, "worth of experience"
    assert_not_includes body, "{", "no merge-field placeholder reaches a reader"
    assert_empty Nokogiri::HTML5(html).css('[data-block="experience"]')
  end

  test "every body link is tracked and none is a raw cyvasse.xyz URL" do
    [ { "username" => "Ann", "wins" => 3 }, { "email" => "ann@example.com" } ].each do |fields|
      _subject, html = render_mail(fields)

      assert_not_includes html, "cyvasse.xyz", "no untracked Cyvasse link in a sent email"
      doc = Nokogiri::HTML5(html)
      keys = doc.css("a[href]").filter_map { |a| a["href"][%r{/e/c/tok-night\?l=(\w+)\z}, 1] }
      %w[night play calendar build].each { |key| assert_includes keys, key, "#{key} goes through the tracker" }

      assert_equal "See Cyvasse Night →", doc.css("a").find { |a| a["href"].end_with?("l=night") }&.text&.squish
      assert_equal "Add it to your calendar", doc.at_css('a[data-link="calendar"]').text.squish
      assert_match %r{/e/c/tok-night\?l=calendar\z}, doc.at_css('a[data-link="calendar"]')["href"]
    end
  end

  test "the body stays about 80 words" do
    _subject, html = render_mail({ "username" => "Ann", "wins" => 30 })
    hook = Nokogiri::HTML5(html).css('[data-block="hook"], [data-block="how"]').map(&:text).join(" ")
    assert_operator hook.split.size, :<=, 90
  end

  test "the editor preview shows the field names in braces" do
    log_in_as(users(:alex))
    get preview_broadcast_path(@broadcast)
    assert_response :success
    assert_includes response.body, "Hi {username},"
    assert_includes response.body, "Bring your {wins} wins"
  end
end
