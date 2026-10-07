# frozen_string_literal: true

require "test_helper"
require_relative "../../support/email_image_fakes"

# [unit] Adding a reference: the type is read from the bytes (not the name),
# over 5 MB is refused, a refused file is never stored, and a good one lands
# under email_brand/<kit>/refs through the shared store. No bucket is reached.
class EmailImages::UploadReferenceTest < ActiveSupport::TestCase
  include EmailImageFakes

  setup { EmailBrandReference.delete_all }

  def with_recording_store(&block)
    stored = []
    store = lambda do |source, prefix:, subject:, **|
      stored << { source: source, prefix: prefix, subject: subject }
      "https://assets.example.test/#{prefix}/#{subject}/#{stored.size}.png"
    end
    Appearances::StoreGeneratedImage.stub(:call, store) { block.call(stored) }
  end

  def upload(file, **attrs)
    EmailImages::UploadReference.call(kit: "turf-monster", file: file, role: "mascot", label: "Gator wave",
                                      note: "use this pose", by: "alex@test.com", **attrs)
  end

  test "a PNG is stored under email_brand/<kit>/refs and filed with its size and dimensions" do
    with_recording_store do |stored|
      ref = upload(uploaded(EmailImageFakes.small_png, name: "gator.png"))

      assert_predicate ref, :persisted?
      assert_equal [["email_brand", "turf-monster/refs"]], stored.map { |s| s.values_at(:prefix, :subject) }
      assert stored.sole[:source].start_with?("data:image/png;base64,")
      assert_equal "https://assets.example.test/email_brand/turf-monster/refs/1.png", ref.image_url
      assert_equal ["image/png", EmailImageFakes.small_png.bytesize, 48, 32, "use this pose", "alex@test.com"],
                   ref.values_at(:content_type, :byte_size, :width, :height, :note, :uploaded_by)
    end
  end

  test "dimensions come from the header, so a PNG declaring 40000x40000 is never decoded" do
    chunk = ->(type, data) { [data.bytesize].pack("N") + type.b + data + [Zlib.crc32(type.b + data)].pack("N") }
    bomb = "\x89PNG\r\n\x1a\n".b + chunk.("IHDR", [40_000, 40_000, 8, 0, 0, 0, 0].pack("NNCCCCC")) +
           chunk.("IDAT", Zlib::Deflate.deflate("\0" * 40_001)) + chunk.("IEND", "".b) # one row: a decode fails
    with_recording_store { assert_equal [40_000, 40_000], upload(uploaded(bomb, name: "b.png")).values_at(:width, :height) }
  end

  test "the type is read from the content: a PNG named .jpg is a PNG" do
    with_recording_store do
      ref = upload(uploaded(EmailImageFakes.small_png, name: "gator.jpg", type: "image/jpeg"))
      assert_equal "image/png", ref.content_type
    end
  end

  test "a text file named .png is refused and nothing is stored" do
    with_recording_store do |stored|
      ref = upload(uploaded("not an image at all", name: "logo.png"))

      refute_predicate ref, :persisted?
      assert_match(/PNG, JPEG or WebP/, ref.errors[:file].join)
      assert_empty stored
    end
  end

  test "a file over 5 MB is refused and nothing is stored" do
    with_recording_store do |stored|
      big = EmailImageFakes.small_png + ("\0" * EmailBrandReference::MAX_BYTES)
      ref = upload(uploaded(big, name: "huge.png"))

      refute_predicate ref, :persisted?
      assert_match(/5 MB/, ref.errors[:file].join)
      assert_empty stored
    end
  end

  test "no file, a bad role or a blank label are refused before any store" do
    with_recording_store do |stored|
      assert_match(/required/, upload(nil).errors[:file].join)
      assert_predicate upload(uploaded(EmailImageFakes.small_png, name: "a.png"), role: "athlete").errors[:role], :any?
      assert_predicate upload(uploaded(EmailImageFakes.small_png, name: "a.png"), label: " ").errors[:label], :any?
      assert_empty stored
      assert_equal 0, EmailBrandReference.count
    end
  end

  test "a store failure files no row and says why" do
    failing = ->(*, **) { raise Appearances::StoreGeneratedImage::StoreFailed, "bucket said no" }
    Appearances::StoreGeneratedImage.stub(:call, failing) do
      ref = upload(uploaded(EmailImageFakes.small_png, name: "a.png"))
      refute_predicate ref, :persisted?
      assert_match(/bucket said no/, ref.errors[:file].join)
    end
    assert_equal 0, EmailBrandReference.count
  end
end
