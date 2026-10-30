require "test_helper"

# [integration] The three return emails (task cyvasse-three-return-emails):
# each renders per reader with and without merge fields, carries one tracked
# play link on the email host that lands on Cyvasse with ?ref=<token>, the
# one-click unsubscribe headers, and no Cyvasse Night copy.
class CyvasseReturnEmailsTest < ActionDispatch::IntegrationTest
  PLAY = "https://cyvasse.mcritchie.studio/".freeze
  KEYS = %w[cyvasse_record cyvasse_challenge cyvasse_founder_note].freeze

  setup do
    @broadcasts = KEYS.to_h do |key|
      [ key, Broadcast.create!(slug: "return-#{key}", template_key: key, subject: "Plain") ]
    end
    @vet = Contact.create!(email: "vet@example.com", traits: { "cyvasse" => {
      "username" => "veyjin", "games" => 57, "wins" => 31, "losses" => 26, "all_time_rank" => 12, "joined_on" => "2015-03-02"
    } })
    @fresh = Contact.create!(email: "fresh@example.com", traits: { "cyvasse" => { "username" => "newbie", "games" => 1 } })
    @guest = Contact.create!(email: "guest@example.com")
  end

  def render(key, contact, delivery = nil) = BroadcastMailer.campaign(@broadcasts.fetch(key), contact, delivery)
  def text(mail) = Nokogiri::HTML5(mail.html_part&.body&.to_s || mail.body.to_s).text.squish
  def hrefs(mail) = Nokogiri::HTML5(mail.body.to_s).css("a[href]").map { |a| a["href"] }

  test "each template is registered with one play link on the email host" do
    assert_equal [ "Cyvasse Return: Your Record", "Cyvasse Return: Your Move", "Cyvasse Return: Founder Note" ],
                 KEYS.map { |key| Broadcast::TEMPLATES[key] }
    KEYS.each do |key|
      assert_equal %w[play], Broadcast::TEMPLATE_LINKS[key].keys
      assert_equal PLAY, @broadcasts[key].link_for("play")
    end
  end

  test "every style renders for every reader with no braces, no Night copy and no cyvasse.xyz" do
    KEYS.product([ @vet, @fresh, @guest ]).each do |key, contact|
      mail = render(key, contact)
      body = text(mail)
      assert_no_match(/\{\w+\}/, body, "#{key} for #{contact.email}")
      assert_no_match(/Cyvasse Night/i, body, key)
      assert_not_includes mail.body.to_s, "cyvasse.xyz", key
    end
  end

  test "record: a veteran sees their games, wins and rank; a newcomer sees the account copy" do
    vet = render("cyvasse_record", @vet)
    assert_equal "veyjin, your 57 games of Cyvasse are still here", vet.subject
    body = text(vet)
    assert_includes body, "Your record is still here"
    assert_includes body, "You played 57 games of Cyvasse since joining in 2015"
    assert_includes body, "your 31 wins"
    assert_includes body, "#12 on the all-time board"
    assert_includes body, "Add to your record"

    fresh = text(render("cyvasse_record", @fresh))
    assert_includes fresh, "Your account is still here"
    assert_includes fresh, "username and all"
    assert_not_includes fresh, "You played"
    assert_equal "Your Cyvasse account is still here", render("cyvasse_record", @guest).subject
  end

  test "challenge: short, game-forward, one Make your move button" do
    mail = render("cyvasse_challenge", @vet)
    assert_equal "veyjin, your move on Cyvasse", mail.subject
    body = text(mail)
    assert_includes body, "Your move."
    assert_includes body, "The dragon is back on the board."
    assert_includes body, "keep your king behind the mountains?"
    assert_includes body, "Make your move"
    assert_not_includes body, "57"
    assert_equal "Your move on Cyvasse", render("cyvasse_challenge", @guest).subject
  end

  test "founder note: a plain letter with no hero image, naming the reader's history when known" do
    mail = render("cyvasse_founder_note", @vet)
    assert_equal "veyjin, I rebuilt Cyvasse", mail.subject
    html = mail.body.to_s
    assert_not_includes html, "cyvasse_header_live.jpg"
    body = text(mail)
    assert_includes body, "A note from Alex"
    assert_includes body, "I built Cyvasse in 2014"
    assert_includes body, "you played 57 games on it after joining in 2015"
    assert_includes body, "Just reply to this email."
    guest = text(render("cyvasse_founder_note", @guest))
    assert_includes guest, "Hi, I’m Alex. I built Cyvasse in 2014. It was the first app I ever made."
    assert_equal "I rebuilt Cyvasse", render("cyvasse_founder_note", @guest).subject
  end

  test "the tracked play link is the only body link, and lands on Cyvasse with ?ref=<token>" do
    KEYS.each do |key|
      delivery = @broadcasts[key].deliveries.create!(contact: @vet)
      links = hrefs(render(key, @vet, delivery))
      play = links.grep(/l=play\z/)
      assert_equal 1, play.size, key
      assert_match %r{/e/c/#{delivery.token}\?l=play\z}, play.first
      assert_empty links - play - links.grep(/unsubscribe/) - links.grep(/l=hero\z/), "#{key}: no other link"

      get email_click_path(token: delivery.token, l: "play")
      assert_redirected_to "#{PLAY}?ref=#{delivery.token}"
    end
  end

  test "each email carries the one-click unsubscribe headers" do
    KEYS.each do |key|
      mail = render(key, @vet, @broadcasts[key].deliveries.create!(contact: @vet))
      assert_match %r{/unsubscribe/#{@vet.unsubscribe_token}}, mail["List-Unsubscribe"].to_s
      assert_equal "List-Unsubscribe=One-Click", mail["List-Unsubscribe-Post"].to_s
    end
  end
end
