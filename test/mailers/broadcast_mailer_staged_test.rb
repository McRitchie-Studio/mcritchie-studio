require "test_helper"

# [component] The "Your games" template and the staged snapshot mail (task
# staged-email-queue): merge fields land in the subject and body, optional
# stats show only when present, the editor's preview shows the field names,
# and the staged mail carries the stored body untouched with its unsubscribe
# headers.
class BroadcastMailerStagedTest < ActionDispatch::IntegrationTest
  setup do
    @broadcast = Broadcast.create!(slug: "your-games-mail", template_key: "cyvasse_your_games",
                                   subject: "%{username}, your %{games} Cyvasse games are still here")
    @contact = Contact.create!(email: "ann@example.com")
  end

  def html(mail) = mail.html_part ? mail.html_part.decoded : mail.decoded

  test "campaign interpolates merge fields into the subject and body, escaping them" do
    fields = { "username" => "<Ann>", "games" => 42, "wins" => 30 }
    mail = BroadcastMailer.campaign(@broadcast, @contact, nil, merge_fields: fields).message

    assert_equal "<Ann>, your 42 Cyvasse games are still here", mail.subject
    body = html(mail)
    assert_includes body, "Hi &lt;Ann&gt;,"
    assert_includes body, "You played <strong>42 games</strong>"
    assert_includes body, "Wins"
    assert_not_includes body, "Losses", "a stat the reader lacks is left out"
  end

  test "the editor preview shows the field names in braces" do
    log_in_as(users(:alex))
    get preview_broadcast_path(@broadcast)
    assert_response :success
    assert_includes response.body, "Hi {username},"
  end

  test "staged sends the stored snapshot untouched, with one-click unsubscribe headers" do
    staged = @broadcast.staged_emails.create!(contact: @contact, status: "approved", email: "ann@example.com",
                                              delivery_token: "tok123", rendered_subject: "Stored subject",
                                              rendered_html: "<p>Stored body — exactly</p>")
    mail = BroadcastMailer.staged(staged).message

    assert_equal [ "ann@example.com" ], mail.to
    assert_equal "Stored subject", mail.subject
    assert_equal "<p>Stored body — exactly</p>", html(mail)
    assert_match %r{/unsubscribe/#{@contact.unsubscribe_token}\?d=tok123>}, mail["List-Unsubscribe"].to_s
    assert_equal "List-Unsubscribe=One-Click", mail["List-Unsubscribe-Post"].to_s
  end

  test "staged refuses a row with no rendered body" do
    staged = @broadcast.staged_emails.create!(contact: @contact, status: "approved", email: "ann@example.com")
    assert_raises(ArgumentError) { BroadcastMailer.staged(staged).message }
  end
end
