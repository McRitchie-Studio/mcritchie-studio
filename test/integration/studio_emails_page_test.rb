require "test_helper"
require "minitest/mock"

# /admin/emails — the engine's standard transactional-email page, adopted by this
# app (Studio::EmailsController over Studio::EmailCatalog, drawn by
# `config.draw_admin_emails_routes = true`). Replaces the retired
# /admin/email_images fork this file used to cover.
#
# This app DECLARES NO EMAIL OF ITS OWN: both are inherited from the engine's
# EmailCatalog::STANDARD seed, and the tests below assert that inheritance rather
# than any local declaration.
#
# It does contribute exactly ONE thing, from config/initializers/studio_emails.rb:
# a `preview:` builder attached to the inherited magic_link entry. Re-registering
# a key updates it in place, so that adds no entry and moves nothing — the
# inheritance claim above still holds, and the test named for it is what keeps
# that true.
#
# S3 is stubbed so no network or credentials are touched; Studio::S3.url stays
# real (a pure string), so the mailer assertion exercises the true public-URL path.
class StudioEmailsPageTest < ActionDispatch::IntegrationTest
  # The saved-copy cache is memoised in the process and does NOT roll back with
  # the transaction, so a test that writes an EmailSetting has to drop it or the
  # next test reads copy it never saved.
  teardown { Studio::EmailSetting.forget! }

  test "the page is admin-only" do
    get admin_emails_path
    assert_redirected_to login_path # unauthenticated

    log_in_as(users(:viewer))
    get admin_emails_path
    assert_redirected_to root_path # authenticated but not admin
  end

  # Acceptance: the page renders BOTH standard emails this app inherits from the
  # engine registry without declaring either of them.
  test "an admin sees both inherited standard emails" do
    log_in_as(users(:alex))
    get admin_emails_path
    assert_response :success

    assert_select "h1", text: "Emails"
    assert_select "a[href=?]", admin_email_path("magic_link"), text: "Magic-link sign-in"

    # COUNTED BY LINK, not by "tbody tr". A list row renders the email's real
    # layered banner, which is an email <table> with rows of its own — so a
    # descendant row selector counts that markup as list rows. One name link per
    # registered email holds on either engine.
    assert_select "tbody a[href^=?]", "/admin/emails/", Studio::EmailCatalog.keys.size
  end

  # The registry is INHERITED, not redeclared here. Guards the scope decision:
  # this app contributes no catalog entries of its own.
  test "the app registers no email of its own" do
    # Compared against the ENGINE's own list rather than a hard-coded pair: the
    # standard set is the engine's to decide, and this app's claim is only that
    # it adds nothing to it.
    assert_equal Studio::EmailCatalog::STANDARD.map { |entry| entry[:key] },
                 Studio::EmailCatalog.keys
  end

  # Acceptance: the admin sidebar points at the shared page.
  test "the sidebar's emails link resolves to this page" do
    log_in_as(users(:alex))
    get admin_dashboard_path
    assert_response :success
    assert_select "a[href=?]", admin_emails_path
  end

  test "an admin uploads a banner and the email then renders it" do
    log_in_as(users(:alex))

    Studio::S3.stub(:upload, ->(**_) { "https://bucket.s3.us-east-2.amazonaws.com/x" }) do
      Studio::S3.stub(:delete, ->(**_) { nil }) do
        assert_difference -> { ImageCache.where(purpose: "email_banner", variant: "magic_link").count }, 1 do
          patch admin_email_path("magic_link"),
                params: { image: fixture_file_upload("magic-banner.png", "image/png") }
        end
      end
    end
    assert_redirected_to admin_emails_path

    record = ImageCache.find_by(owner: nil, purpose: "email_banner", variant: "magic_link")
    assert record.present?, "an owner-less ImageCache row should be created"
    assert_equal Studio::EmailCatalog.url(:magic_link), record.url

    token = Studio::Link.create_magic_link(email: "x@example.com").token
    mail = UserMailer.magic_link("x@example.com", token)
    html = (mail.html_part&.body || mail.body).to_s
    assert_includes html, record.s3_key, "the branded email should render the managed banner"
  end

  test "uploading a re-upload replaces the prior object (no duplicate rows)" do
    log_in_as(users(:alex))
    Studio::S3.stub(:upload, ->(**_) { "u" }) do
      Studio::S3.stub(:delete, ->(**_) { nil }) do
        2.times do
          patch admin_email_path("magic_link"),
                params: { image: fixture_file_upload("magic-banner.png", "image/png") }
        end
      end
    end
    assert_equal 1, ImageCache.where(purpose: "email_banner", variant: "magic_link").count
  end

  test "a non-image upload is rejected" do
    log_in_as(users(:alex))
    patch admin_email_path("magic_link"),
          params: { image: fixture_file_upload("notes.txt", "text/plain") }
    assert_redirected_to admin_emails_path
    # The formats the message names have grown (GIF joined them once animated
    # banners could be uploaded whole), so assert the part that identifies the
    # message rather than its full wording.
    assert_match(/png, jpg/i, flash[:alert])
  end

  test "an unknown key 404s" do
    log_in_as(users(:alex))
    patch admin_email_path("nonsense")
    assert_response :not_found
  end

  # --- the preview ------------------------------------------------------------
  #
  # Registering a preview builder is what turns the copy fields on this page from
  # text boxes into something an operator can check. It also creates a SECOND
  # rendering of the sign-in email, and a second rendering is a thing that can
  # disagree with the first. These assert it does not.

  test "the magic-link email is previewable at all" do
    assert Studio::EmailCatalog.previewable?(:magic_link),
      "config/initializers/studio_emails.rb registers the builder; without it the " \
      "page shows 'No preview is registered' and the copy fields cannot be checked"

    log_in_as(users(:alex))
    get admin_email_path("magic_link")
    assert_response :success
    assert_select "iframe[src=?]", admin_email_raw_path("magic_link")
    assert_select "p", { text: /No preview is registered/, count: 0 },
      "the page must not still be offering the empty state"
  end

  # THE PROPERTY THIS SURFACE KEEPS BREAKING: the manager showing something the
  # inbox never receives.
  #
  # Asserted as WHOLE-DOCUMENT equality rather than by spot-checking a phrase.
  # Every prior defect here was a page answering from the field it happened to
  # read instead of from what ships, and any assertion narrow enough to name a
  # phrase is narrow enough to miss the next one. The preview is fetched through
  # the REAL route the iframe loads, so it exercises the registration too — a
  # builder pointed at some other mail fails here.
  test "the preview iframe renders the very document the recipient receives" do
    log_in_as(users(:alex))
    get admin_email_raw_path("magic_link")
    assert_response :success

    assert_nil Studio::EmailCatalog.preview_error("magic_link"),
      "the builder raised; the page would be showing an error card instead of the email"

    sent = UserMailer.magic_link(UserMailer.preview_recipient, UserMailer::PREVIEW_TOKEN)
    sent_html = (sent.html_part&.body || sent.body).to_s

    assert sent_html.present?, "the control is the real send — it must have rendered"
    assert_equal sent_html, response.body,
      "what /admin/emails draws and what the mailer sends have diverged"
  end

  # The operator-facing half: the point of the preview is seeing copy RESOLVED.
  # A preview that renders "Hi {name}," is the raw template with extra steps.
  #
  # Reads the name back out of the banner rather than restating that the mailer
  # derives it from display_name — the banner has always carried it, so it is the
  # control, and an assertion that re-implements the derivation would pass even if
  # both halves drifted together.
  test "the preview resolves the operator's placeholders instead of showing them" do
    Studio::EmailSetting.find_or_initialize_by(email_key: "magic_link")
                        .update!(body: "Hi {name}, tap the button to sign in to {app}.",
                                 cta_text: "Sign in, {name}")
    Studio::EmailSetting.forget!

    log_in_as(users(:alex))
    get admin_email_raw_path("magic_link")
    assert_response :success

    greeted = response.body[/font-weight:700;color:#ffffff;">\s*Welcome ([^<!]+)!/, 1]&.strip
    assert greeted.present?, "the banner carries the name — it is the control for this test"

    assert_includes response.body, "Hi #{greeted}, tap the button",
      "the body must show the operator's copy with the name filled in"
    assert_includes response.body, "Sign in, #{greeted}",
      "the button must show it too — it is edited on the same page"
    refute_includes response.body, "{name}"
    refute_includes response.body, "{app}"
  end
end
