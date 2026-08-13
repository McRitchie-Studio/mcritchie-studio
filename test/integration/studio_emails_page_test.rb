require "test_helper"
require "minitest/mock"

# /admin/emails — the engine's standard transactional-email page, adopted by this
# app (Studio::EmailsController over Studio::EmailCatalog, drawn by
# `config.draw_admin_emails_routes = true`). Replaces the retired
# /admin/email_images fork this file used to cover.
#
# This app REGISTERS NOTHING: both emails are inherited from the engine's
# EmailCatalog::STANDARD seed. The tests below assert that inheritance rather
# than any local declaration.
#
# S3 is stubbed so no network or credentials are touched; Studio::S3.url stays
# real (a pure string), so the mailer assertion exercises the true public-URL path.
class StudioEmailsPageTest < ActionDispatch::IntegrationTest
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
end
