require "test_helper"

# The sign-in email's LAYERED banner, at this app's own mailer.
#
# McRitchie Studio defines its own UserMailer, so the engine's is never loaded
# here — this file is the only place that can prove this app layers. The
# division of labour it protects: the mailer supplies WHO the recipient is, and
# /admin/emails supplies what the banner says about them. A mailer that hands
# over a finished header instead takes the wording away from the operator, and
# the manager's fields then accept edits no inbox ever sees.
class UserMailerTest < ActionMailer::TestCase
  def html_for(email)
    message = UserMailer.magic_link(email, "token-for-test-1234")
    [(message.html_part&.body || message.body).to_s, message]
  end

  def banner_header(html) = html[/font-weight:700;color:#ffffff;">\s*([^<]+)/, 1]&.strip

  test "a known recipient is greeted by name" do
    html, = html_for(users(:alex).email)

    assert_equal "Welcome Alex!", banner_header(html)
  end

  # A magic link is often the FIRST thing a stranger receives, so the name-free
  # path is not a rare branch — and "Welcome !" is what it renders without the
  # fallback header.
  test "a stranger gets the name-free header, not an empty greeting" do
    html, = html_for("nobody-here@example.test")

    assert_equal "Your Magic Link", banner_header(html)
    refute_includes html, "Welcome !"
  end

  test "the layered banner carries the artwork, not just text" do
    html, = html_for(users(:alex).email)

    assert_includes html, "background-size:cover", "the banner should render its background"
    assert_includes html, "v:rect", "Outlook renders through Word and needs the VML block"
  end

  # The subject reads from the same catalogue as the banner, so an operator's
  # edit reaches the inbox list too — and no raw placeholder may survive.
  test "the subject resolves through the catalogue" do
    _, message = html_for(users(:alex).email)

    assert_includes message.subject, Studio.app_name
    refute_includes message.subject, "{app}"
    refute_includes message.subject, "{name}"
  end

  test "the token still reaches the recipient" do
    html, message = html_for(users(:alex).email)

    assert_includes html, "token-for-test-1234", "the sign-in link is the point of the email"
    assert_equal [users(:alex).email], message.to
  end
end
