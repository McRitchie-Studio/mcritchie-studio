require "test_helper"

# [integration] The "How was your first game" email (task
# first-game-feedback-survey): registered, rendered per reader with the
# subject their username picks, one button to the survey through the click
# tracker, and the tracker landing the reader on the survey with ?t=<token>.
class CyvasseFirstGameEmailTest < ActionDispatch::IntegrationTest
  setup do
    @broadcast = Broadcast.create!(slug: "first-game-email", template_key: "cyvasse_first_game",
                                   subject: Broadcasts::CyvasseFirstGame::PLAIN_SUBJECT)
    @vey = Contact.create!(email: "vey@example.com", traits: { "cyvasse" => { "username" => "veyjin" } })
    @guest = Contact.create!(email: "guest@example.com")
    @delivery = @broadcast.deliveries.create!(contact: @vey)
  end

  def render_for(contact, delivery = nil) = BroadcastMailer.campaign(@broadcast, contact, delivery)
  def text(mail) = Nokogiri::HTML5(mail.html_part&.body&.to_s || mail.body.to_s).text.squish

  test "the template is registered with its survey and build links, and needs no merge field" do
    assert_equal "Cyvasse: How Was Your First Game", Broadcast::TEMPLATES["cyvasse_first_game"]
    assert_equal %w[survey build], Broadcast::TEMPLATE_LINKS["cyvasse_first_game"].keys
    assert_equal "https://mcritchie.studio/s/cyvasse-first-game", @broadcast.link_for("survey")
    assert_not @broadcast.requires_staging?
  end

  test "the subject names the reader when their username is known" do
    assert_equal "veyjin, how was your first game on the new Cyvasse?", render_for(@vey).subject
    assert_equal "How was your first game on the new Cyvasse?", render_for(@guest).subject
  end

  test "the body thanks them, says it was rebuilt, and that Alex reads every answer" do
    body = text(render_for(@vey, @delivery))
    assert_includes body, "Hi veyjin,"
    assert_includes body, "Thank you for playing Cyvasse."
    assert_includes body, "rebuilt it from scratch"
    assert_includes body, "I read every answer"
    assert_includes body, "Tell us how it went"
    assert_includes text(render_for(@guest)), "Hi,"
    assert_no_match(/Cyvasse Night/i, body)
  end

  test "the body is about sixty words" do
    words = text(render_for(@vey, @delivery))[/Hi veyjin,.*?— Alex/].split.size
    assert_operator words, :<=, 70
  end

  test "every link goes through the tracker; the button is l=survey; no raw cyvasse.xyz URL" do
    html = render_for(@vey, @delivery).body.to_s
    hrefs = Nokogiri::HTML5(html).css("a[href]").map { |a| a["href"] }
    survey = hrefs.grep(/l=survey/)
    assert_equal 1, survey.size, "one survey button"
    assert_match %r{/e/c/#{@delivery.token}\?l=survey\z}, survey.first
    assert(hrefs.any? { |href| href.include?("l=build") }, "the P.S. build link is tracked")
    assert_not_includes html, "cyvasse.xyz"
  end

  test "the tracked survey click lands on the survey with ?t=<token>" do
    get email_click_path(token: @delivery.token, l: "survey")
    assert_redirected_to "https://mcritchie.studio/s/cyvasse-first-game?t=#{@delivery.token}"
    assert_equal "survey", @delivery.events.where(kind: "clicked").last&.link_key
  end
end
