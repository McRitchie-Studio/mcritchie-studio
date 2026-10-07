require "test_helper"

# [integration] The play-times email (task cyvasse-play-times-email): registered,
# rendered per reader with the subject their username picks, one button plus a
# plain link to Cyvasse's play-times survey through the click tracker, the
# tracker landing the reader there with ?ref=<token>, and the one-click
# unsubscribe headers.
class CyvassePlayTimesEmailTest < ActionDispatch::IntegrationTest
  SURVEY = "https://cyvasse.mcritchie.studio/surveys/play-times".freeze

  setup do
    @broadcast = Broadcast.create!(slug: "play-times-email", template_key: "cyvasse_play_times",
                                   subject: Broadcasts::CyvassePlayTimes::PLAIN_SUBJECT)
    @vey = Contact.create!(email: "vey@example.com", traits: { "cyvasse" => { "username" => "veyjin" } })
    @guest = Contact.create!(email: "guest@example.com")
    @delivery = @broadcast.deliveries.create!(contact: @vey)
  end

  def render_for(contact, delivery = nil) = BroadcastMailer.campaign(@broadcast, contact, delivery)
  def text(mail) = Nokogiri::HTML5(mail.html_part&.body&.to_s || mail.body.to_s).text.squish
  def hrefs(mail) = Nokogiri::HTML5(mail.body.to_s).css("a[href]").map { |a| a["href"] }

  test "the template is registered with one survey link on the email host, and needs no merge field" do
    assert_equal "Cyvasse: Play Times Survey", Broadcast::TEMPLATES["cyvasse_play_times"]
    assert_equal %w[survey], Broadcast::TEMPLATE_LINKS["cyvasse_play_times"].keys
    assert_equal SURVEY, @broadcast.link_for("survey")
    assert_equal "cyvasse.mcritchie.studio", URI(@broadcast.link_for("survey")).host
    assert_not @broadcast.requires_staging?
  end

  test "the subject names the reader when their username is known, plain otherwise" do
    assert_equal "veyjin, how was your first game on the new Cyvasse?", render_for(@vey).subject
    assert_equal "How was your first game on the new Cyvasse?", render_for(@guest).subject
  end

  test "the body opens with Hi, asks about the first game, then the Cyvasse Night times" do
    [ text(render_for(@vey, @delivery)), text(render_for(@guest)) ].each do |body|
      assert_includes body, "Hi \u{1F44B}\u{1F3FB}"
      assert_includes body, "How was your first game on the new Cyvasse?"
      assert_includes body, "Cyvasse Night, every other week"
      assert_includes body, "Tell us when you’re free"
      assert_includes body, "30 seconds"
      assert_includes body, "Tell us (30 seconds)"
      assert_includes body, "cyvasse.mcritchie.studio/surveys/play-times"
    end
    assert_operator text(render_for(@vey, @delivery)).index("How was your first game"),
                    :<, text(render_for(@vey, @delivery)).index("Cyvasse Night, every other week")
  end

  test "the body is three or four short sentences" do
    body = text(render_for(@vey, @delivery))[/Hi \u{1F44B}\u{1F3FB}(.*?)Tell us \(30 seconds\)/, 1]
    assert_includes 3..4, body.scan(/[.?!](\s|\z)/).size
    assert_operator body.split.size, :<=, 60
  end

  test "both survey links are the tracked l=survey link; no other ask; no cyvasse.xyz" do
    mail = render_for(@vey, @delivery)
    links = hrefs(mail)
    survey = links.grep(/l=survey/)
    assert_equal 2, survey.size, "the button and the plain link"
    survey.each { |href| assert_match %r{/e/c/#{@delivery.token}\?l=survey\z}, href }
    # The shared layout's tracked header image (l=hero) and unsubscribe link
    # are the only others; the body adds no second ask.
    assert_empty links - survey - links.grep(/unsubscribe/) - links.grep(/l=hero\z/), "no other link in the body"
    assert_not_includes mail.body.to_s, "cyvasse.xyz"
  end

  test "an untracked render (the editor preview) links straight to the survey on cyvasse.mcritchie.studio" do
    survey = hrefs(render_for(@guest)).grep(%r{surveys/play-times})
    assert_equal [ SURVEY, SURVEY ], survey
  end

  test "the tracked survey click lands on Cyvasse's survey with ?ref=<token>" do
    get email_click_path(token: @delivery.token, l: "survey")
    assert_redirected_to "#{SURVEY}?ref=#{@delivery.token}"
    assert_equal "survey", @delivery.events.where(kind: "clicked").last&.link_key
  end

  test "the email carries the one-click unsubscribe headers" do
    mail = render_for(@vey, @delivery)
    assert_match %r{\A<https?://[^>]+/unsubscribe/#{@vey.unsubscribe_token}[^>]*>\z}, mail["List-Unsubscribe"].to_s
    assert_equal "List-Unsubscribe=One-Click", mail["List-Unsubscribe-Post"].to_s
  end
end
