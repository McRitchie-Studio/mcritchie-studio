require "test_helper"

# [integration] The four designed emails (task cyvasse-four-prong-emails): each
# renders per reader in the bare layout with no Studio chrome, its links on the
# email host, an unsubscribe link and header, and no braces.
class CyvasseFourEmailsTest < ActionDispatch::IntegrationTest
  PLAY = "https://cyvasse.mcritchie.studio/".freeze
  KEYS = %w[cyvasse_poster cyvasse_pick cyvasse_wrapped cyvasse_dragon].freeze

  setup do
    @broadcasts = KEYS.to_h { |key| [ key, Broadcast.create!(slug: "four-#{key}", template_key: key, subject: "Plain") ] }
    @vet = Contact.create!(email: "vet@example.com", traits: { "cyvasse" => {
      "username" => "veyjin", "games" => 57, "wins" => 31, "losses" => 26, "all_time_rank" => 12, "joined_on" => "2015-03-02"
    } })
    @fresh = Contact.create!(email: "fresh@example.com", traits: { "cyvasse" => { "username" => "newbie", "games" => 1 } })
    @guest = Contact.create!(email: "guest@example.com")
  end

  def render(key, contact, delivery = nil) = BroadcastMailer.campaign(@broadcasts.fetch(key), contact, delivery)
  def html(mail) = mail.html_part&.body&.to_s || mail.body.to_s
  def text(mail) = Nokogiri::HTML5(html(mail)).css("body").text.squish

  test "every style renders for every reader without braces, chrome or a stray host" do
    KEYS.product([ @vet, @fresh, @guest ]).each do |key, contact|
      mail = render(key, contact)
      assert_no_match(/\{\w+\}/, text(mail), "#{key} for #{contact.email}")
      assert_no_match(/McRitchie.Studio Studio|studio-logo-white/, html(mail), key)
      assert_no_match(/cyvasse\.xyz/, html(mail), key)
      assert_match "Unsubscribe", text(mail), key
      assert mail["List-Unsubscribe"].present?, key
    end
  end

  test "the veteran sees their own numbers and the guest sees none" do
    assert_match "#12", text(render("cyvasse_wrapped", @vet))
    assert_match "54%", text(render("cyvasse_wrapped", @vet))
    assert_match "2015", text(render("cyvasse_wrapped", @vet))
    %w[cyvasse_poster cyvasse_dragon].each do |key|
      assert_match "57", text(render(key, @vet)), key
      assert_no_match(/ALL-TIME/, text(render(key, @guest)), key)
    end
    assert_match "Your 57 games came with it", text(render("cyvasse_pick", @vet))
    assert_match "Your account", text(render("cyvasse_dragon", @guest))
  end

  test "a sent email tracks every link and carries the open pixel" do
    KEYS.each do |key|
      broadcast = @broadcasts[key]
      delivery = broadcast.deliveries.create!(contact: @vet)
      doc = Nokogiri::HTML5(html(render(key, @vet, delivery)))
      tracked = doc.css("a[href]").map { |a| a["href"] }.reject { |href| href.include?("unsubscribe") }
      assert tracked.any?, key
      assert tracked.all? { |href| href.include?("l=") && href.include?(delivery.token) }, key
      assert doc.css("img[src*='#{delivery.token}']").any?, key
    end
  end

  test "each answer on The Pick is its own link and all land on the game" do
    broadcast = @broadcasts["cyvasse_pick"]
    assert_equal %w[catapult dragon elephant heavyhorse], Broadcast::TEMPLATE_LINKS["cyvasse_pick"].keys.sort
    Broadcast::TEMPLATE_LINKS["cyvasse_pick"].each_key { |key| assert_equal PLAY, broadcast.link_for(key) }
  end

  test "a click lands on Cyvasse with ?ref=<token>, from every link" do
    KEYS.each do |key|
      delivery = @broadcasts[key].deliveries.create!(contact: @vet)
      Broadcast::TEMPLATE_LINKS[key].each_key do |link|
        get email_click_path(token: delivery.token, l: link)
        assert_redirected_to "#{PLAY}?ref=#{delivery.token}"
      end
    end
  end

  test "a staged snapshot keeps its pixel, tracked links and unsubscribe" do
    KEYS.each do |key|
      broadcast = @broadcasts[key]
      reader = Contact.create!(email: "#{key}@example.com", tags: [ "cyvasse-legacy" ], verification_status: "valid", traits: @vet.traits)
      broadcast.stage!(audience: "cyvasse-legacy", filter: { id: reader.id })
      row = broadcast.staged_emails.find_by!(contact: reader)
      assert_equal "staged", row.status, row.skip_reason
      assert_match "/e/o/", row.rendered_html, key
      assert_match "/e/c/", row.rendered_html, key
      assert BroadcastMailer.staged(row)["List-Unsubscribe"].present?, key
      assert_match "veyjin", row.rendered_subject.to_s + row.rendered_html, key
    end
  end

  test "counts of one read singular" do
    one = Contact.create!(email: "one@example.com", traits: { "cyvasse" => { "username" => "solo", "games" => 7, "wins" => 1, "losses" => 1 } })
    assert_match "1 win, 1 loss", text(render("cyvasse_wrapped", one))
    %w[cyvasse_poster cyvasse_dragon].each { |key| assert_match(/1\s*WIN\b/, text(render(key, one)), key) }
  end

  test "a long username steps the Pick headline down" do
    long = Contact.create!(email: "long@example.com", traits: { "cyvasse" => { "username" => "averyveryverylongname", "games" => 7 } })
    assert_match "font-size:32px", html(render("cyvasse_pick", long))
    assert_match "font-size:44px", html(render("cyvasse_pick", @vet))
  end

  test "the Dragon's fallback colour keeps its copy readable with images off" do
    assert_match 'bgcolor="#c8324b"', html(render("cyvasse_dragon", @vet))
  end

  test "a forty-character username can wrap in every style" do
    long = Contact.create!(email: "forty@example.com", traits: { "cyvasse" => { "username" => "a" * 40, "games" => 7 } })
    KEYS.each { |key| assert_match "word-break:break-word", html(render(key, long)), key }
  end

  test "a reader without history gets natural copy" do
    assert_no_match(/ADD TO YOUR RECORD/, text(render("cyvasse_poster", @guest)))
    assert_match "Back.", text(render("cyvasse_wrapped", @guest))
  end

  test "the footer prints an address only when MAILER_ADDRESS is set" do
    original = ENV.delete("MAILER_ADDRESS")
    KEYS.each do |key|
      assert_no_match(/Denver, CO/, text(render(key, @vet)), key)
      assert_no_match(/<br>\s*<br>\s*<a [^>]*>Unsubscribe/, html(render(key, @vet)), key)
      assert_match "Unsubscribe", text(render(key, @vet)), key
    end
    ENV["MAILER_ADDRESS"] = "PO Box 1, Denver, CO 80205"
    KEYS.each { |key| assert_match "PO Box 1, Denver, CO 80205", text(render(key, @vet)), key }
  ensure
    original ? ENV["MAILER_ADDRESS"] = original : ENV.delete("MAILER_ADDRESS")
  end

  test "The Wrapped leads with games played and won" do
    body = text(render("cyvasse_wrapped", @vet))
    assert_match "VEYJIN, YOU PLAYED", body
    assert_match "Games of Cyvasse played.", body
    assert_operator body.index("YOU PLAYED"), :<, body.index("YOU WON")
    assert_operator body.index("YOU WON"), :<, body.index("The year you joined.")
  end

  test "the Dragon and Pick emails use the vector piece art" do
    assert_match "cyvasse_hex_dragon_glass.png", html(render("cyvasse_dragon", @vet))
    assert_equal 4, html(render("cyvasse_pick", @vet)).scan(/cyvasse_vector_\w+\.png/).uniq.size
  end

  test "every image a template names is in public/email" do
    KEYS.each do |key|
      Nokogiri::HTML5(html(render(key, @vet))).css("img").each do |img|
        name = img["src"][%r{/email/([^/?]+)\z}, 1]
        assert name && Rails.root.join("public/email", name).exist?, "#{key}: #{img['src']}"
      end
    end
  end

  test "the editor preview renders in the bare layout" do
    log_in_as(users(:alex))
    KEYS.each do |key|
      get preview_broadcast_path(@broadcasts[key])
      assert_response :success
      assert_no_match(/studio-logo-white/, response.body, key)
      assert_match "{games}", response.body, key unless key == "cyvasse_pick"
      assert_match "{all_time_rank}", response.body, key if key == "cyvasse_wrapped"
    end
    assert_equal "broadcast_email", Broadcast.new(template_key: "cyvasse_record").email_layout
  end
end
