# frozen_string_literal: true

require "test_helper"
require_relative "../../support/email_image_fakes"

# [unit] The crop is deterministic and exact: the image tool's 1536x1024 in,
# exactly 1200x600 out, JPG or PNG, under the email byte budget.
class EmailImages::CropTest < ActiveSupport::TestCase
  test "a 1536x1024 data URI crops to exactly 1200x600 JPG under budget" do
    out = EmailImages::Crop.call(EmailImageFakes.vendor_data_uri, width: 1200, height: 600)

    image = MiniMagick::Image.read(out.bytes)
    assert_equal [1200, 600], [image.width, image.height]
    assert_equal "JPEG", image.type
    assert_equal "image/jpeg", out.content_type
    assert_operator out.bytesize, :<, 300_000
    assert_not out.over_budget?
  end

  test "PNG is honoured and still exact" do
    out = EmailImages::Crop.call(EmailImageFakes.vendor_png, width: 1200, height: 600, format: "png")

    image = MiniMagick::Image.read(out.bytes)
    assert_equal [1200, 600, "PNG"], [image.width, image.height, image.type]
    assert_operator out.bytesize, :<, 300_000, "an over-budget PNG is quantized to fit"
  end

  test "the same input yields the same bytes" do
    a = EmailImages::Crop.call(EmailImageFakes.vendor_png, width: 1200, height: 600)
    b = EmailImages::Crop.call(EmailImageFakes.vendor_png, width: 1200, height: 600)
    assert_equal Digest::SHA256.hexdigest(a.bytes), Digest::SHA256.hexdigest(b.bytes)
  end

  test "a tight budget steps JPG quality down" do
    out = EmailImages::Crop.call(EmailImageFakes.vendor_png, width: 1200, height: 600, max_bytes: 40_000)
    assert_operator out.quality, :<, 85
  end

  test "a URL is refused rather than fetched" do
    assert_raises(EmailImages::Crop::CropFailed) do
      EmailImages::Crop.call("https://example.com/a.png", width: 1200, height: 600)
    end
  end
end
