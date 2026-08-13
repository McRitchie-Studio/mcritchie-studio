require "test_helper"

# The sign-in email's OPERATOR-AUTHORED COPY — the body paragraph and the CTA
# label editable on /admin/emails.
#
# This app SHADOWS the engine's UserMailer but not its view: there is no
# app/views/user_mailer/ here, so the engine's magic_link.html.erb renders. That
# split is the whole reason these guards exist. The engine wired @body/@cta_text
# with the recipient's name in 0.43, and none of it reached this app, because
# the shadowing class never set them — so the view fell back to
# EmailCatalog.body(:magic_link) with no name.
#
# Nothing raised and no placeholder leaked when it was broken: the registry
# tidies an unfillable "{name}" out of the copy, so "Hi {name}," rendered as a
# perfectly grammatical "Hi,". That is why these assert the RESOLVED name rather
# than the absence of a placeholder — a test for a leaked "{name}" passes on the
# broken code.
class UserMailerTest < ActionMailer::TestCase
  BODY = "Hi {name}, tap the button to sign in to {app}.".freeze

  # THE CTA TEMPLATE CARRIES {name} TOO, and saving it here is what gives the CTA
  # guard below something that can fail.
  #
  # It did not, and the guard was decorative as a direct result. The registry
  # default is "Sign in to {app}" — no {name} anywhere — so the old assertion
  # ("Sign" appears, "{name}" does not) held whether or not the mailer passed the
  # recipient through. MEASURED: dropping `name:` from @cta_text left the whole
  # file green. A guard for an unresolved placeholder needs a placeholder to
  # resolve, and only the setup can put one there.
  CTA = "Sign in, {name}".freeze

  setup do
    Studio::EmailSetting.find_or_initialize_by(email_key: "magic_link")
                        .update!(body: BODY, cta_text: CTA)
    Studio::EmailSetting.forget!
  end

  teardown { Studio::EmailSetting.forget! }

  def render_email(email)
    message = UserMailer.magic_link(email, "token-for-test-1234")
    [ (message.html_part&.body || message.body).to_s, message ]
  end

  def banner_header(html)
    html[/font-weight:700;color:#ffffff;">\s*([^<]+)/, 1]&.strip
  end

  # --- the operator's copy actually ships ------------------------------------

  test "the operator's body copy reaches the inbox" do
    html, = render_email(users(:alex).email)

    assert_includes html, "tap the button to sign in to",
      "the body saved on /admin/emails is what the email should say"
  end

  # THE DEFECT THIS TASK FIXES, stated as the symptom that made it visible: the
  # banner greeted the recipient by name while the paragraph directly under it
  # opened "Hi,". One email, disagreeing with itself.
  # Reads the name back OUT of the banner rather than restating how the mailer
  # derives it (display_name, which is "Alex", not the fixture's "Alex
  # McRitchie"). Asserting a re-implementation would pass even if both halves
  # drifted together; this fails the moment they disagree, which is the defect.
  test "the banner and the body greet the same recipient" do
    html, = render_email(users(:alex).email)

    greeted = banner_header(html).to_s[/Welcome (.+)!/, 1]
    assert greeted.present?,
      "the banner has always carried the name — it is the control for this test"

    assert_includes html, "Hi #{greeted},",
      "the body must resolve the same name the banner just used"
  end

  test "the app placeholder resolves too" do
    html, = render_email(users(:alex).email)

    assert_includes html, "sign in to #{Studio.app_name}"
    refute_includes html, "{app}"
  end

  # --- the stranger path ------------------------------------------------------

  # A magic link is often the FIRST thing someone receives, so there is no
  # account and no name. The copy must stay grammatical rather than rendering
  # "Hi ," or a raw token.
  test "a stranger gets grammatical copy with no name and no placeholder" do
    html, = render_email("nobody-here@example.test")

    assert_includes html, "Hi, tap the button"
    refute_includes html, "{name}"
    refute_includes html, "Hi ,"

    # The BUTTON has to survive the same treatment, and it is the harder case: a
    # header has a second field to fall back to and a button label does not, so
    # the placeholder and the punctuation holding it both have to go. "Sign in,
    # {name}" reads "Sign in" — never "Sign in," with the comma left hanging.
    assert_includes html, "Sign in", "the stranger still needs a button to press"
    refute_includes html, "Sign in,"
  end

  # --- the CTA ---------------------------------------------------------------

  # THE BUTTON IS THE SECOND HALF OF THE SAME DEFECT. @body and @cta_text are set
  # on adjacent lines from the same name_for(email), so the copy can lose the
  # recipient in the button while the paragraph above it keeps him.
  #
  # Reads the name back OUT of the banner, exactly as the body test does, rather
  # than restating that the mailer derives it from display_name. The banner is the
  # control: it has carried the name since before any of this, so if it is missing
  # the test says so instead of quietly passing.
  #
  # The expected label is built from CTA rather than typed out, so the setup and
  # the assertion cannot drift apart.
  test "the CTA label resolves the recipient's name" do
    html, = render_email(users(:alex).email)

    greeted = banner_header(html).to_s[/Welcome (.+)!/, 1]
    assert greeted.present?,
      "the banner has always carried the name — it is the control for this test"

    assert_includes html, CTA.sub("{name}", greeted),
      "the button must resolve the same name the banner just used"
    refute_includes html, "{name}"
  end

  # --- still a sign-in email --------------------------------------------------

  test "the link still reaches the recipient" do
    html, message = render_email(users(:alex).email)

    assert_includes html, "token-for-test-1234", "the link is the point of the email"
    assert_equal [ users(:alex).email ], message.to
  end

  # The subject is the most visible place a {name} can leak. It SAVES a subject
  # containing {name}: against the registry default (none) this passes on broken code.
  test "the subject resolves the recipient and leaks no placeholder" do
    Studio::EmailSetting.find_or_initialize_by(email_key: "magic_link").update!(subject: "Your {app} link, {name}")
    Studio::EmailSetting.forget!
    _, message = render_email(users(:alex).email)
    assert_includes message.subject, "Alex"
    refute_includes message.subject, "{name}"
  end

  # A transient lookup failure must cost the NAME, never the SEND — a raise escaping
  # name_for locks the recipient out of their own account.
  test "a failing name lookup still sends the email, name-free" do
    recipient = users(:alex).email # resolved BEFORE the stub; the accessor calls find_by!
    raiser = ->(*_args, **_kwargs) { raise ActiveRecord::StatementInvalid, "connection lost" }

    User.stub(:find_by, raiser) do
      html, message = render_email(recipient)

      assert_equal "Your Magic Link", banner_header(html)
      assert_includes html, "token-for-test-1234", "the sign-in link must still ship"
      assert_equal [ recipient ], message.to
    end
  end
end
