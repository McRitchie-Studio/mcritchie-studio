require "test_helper"
require "minitest/mock"

# Admin-managed email banner (Studio::EmailImage + Studio::EmailImagesController),
# the [component]/[integration] tier for the email-image half of the epic. S3 is
# stubbed so no network/credentials are touched; Studio::S3.url stays real (pure
# string), so the mailer assertion exercises the true public-URL path.
class StudioEmailImageTest < ActionDispatch::IntegrationTest
  test "the page is admin-only" do
    get admin_email_images_path
    assert_redirected_to login_path # unauthenticated

    log_in_as(users(:viewer))
    get admin_email_images_path
    assert_redirected_to root_path # authenticated but not admin
  end

  test "an admin sees the managed email variants" do
    log_in_as(users(:alex))
    get admin_email_images_path
    assert_response :success
    assert_select "h2", text: "Magic-link sign-in"
  end

  test "an admin uploads a banner and the email then renders it" do
    log_in_as(users(:alex))

    Studio::S3.stub(:upload, ->(**_) { "https://bucket.s3.us-east-2.amazonaws.com/x" }) do
      Studio::S3.stub(:delete, ->(**_) { nil }) do
        assert_difference -> { ImageCache.where(purpose: "email_banner", variant: "magic_link").count }, 1 do
          patch admin_email_image_path("magic_link"),
                params: { image: fixture_file_upload("magic-banner.png", "image/png") }
        end
      end
    end
    assert_redirected_to admin_email_images_path

    record = ImageCache.find_by(owner: nil, purpose: "email_banner", variant: "magic_link")
    assert record.present?, "an owner-less ImageCache row should be created"
    assert_equal Studio::EmailImage.url(:magic_link), record.url

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
          patch admin_email_image_path("magic_link"),
                params: { image: fixture_file_upload("magic-banner.png", "image/png") }
        end
      end
    end
    assert_equal 1, ImageCache.where(purpose: "email_banner", variant: "magic_link").count
  end

  test "a non-image upload is rejected" do
    log_in_as(users(:alex))
    patch admin_email_image_path("magic_link"),
          params: { image: fixture_file_upload("notes.txt", "text/plain") }
    assert_redirected_to admin_email_images_path
    assert_match(/png, jpg, or webp/i, flash[:alert])
  end

  test "an unknown variant 404s" do
    log_in_as(users(:alex))
    patch admin_email_image_path("nonsense")
    assert_response :not_found
  end
end
