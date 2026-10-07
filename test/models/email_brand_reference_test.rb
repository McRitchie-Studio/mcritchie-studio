# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [unit] An uploaded brand reference: a known kit, a role from the list, a
# label, a content type read from bytes, and archive keeps the row.
class EmailBrandReferenceTest < ActiveSupport::TestCase
  include EmailImageFakes

  setup { EmailBrandReference.delete_all }

  test "a valid row gets a slug and starts active" do
    ref = brand_reference
    assert_match(/\Aref-[0-9a-f]{12}\z/, ref.slug)
    assert_includes EmailBrandReference.active, ref
    refute_predicate ref, :archived?
  end

  test "it refuses an unknown kit, an unknown role, a blank label and an oversize byte count" do
    ref = EmailBrandReference.new(brand_kit: "acme", role: "athlete", label: "", image_url: "https://x.test/a.png",
                                  content_type: "image/gif", byte_size: EmailBrandReference::MAX_BYTES + 1)
    refute_predicate ref, :valid?
    assert_equal %i[brand_kit byte_size content_type label role].sort, ref.errors.attribute_names.uniq.sort
  end

  test "archive keeps the row and drops it from active" do
    ref = brand_reference
    ref.archive!
    assert_predicate ref.reload, :archived?
    assert_not_includes EmailBrandReference.active, ref
    assert_includes EmailBrandReference.archived, ref
  end

  test "the content type comes from the bytes" do
    assert_equal "image/png", EmailBrandReference.content_type_of(EmailImageFakes.small_png)
    assert_equal "image/jpeg", EmailBrandReference.content_type_of("\xFF\xD8\xFF\xE0rest".b)
    assert_equal "image/webp", EmailBrandReference.content_type_of(File.binread(Rails.root.join("public/agents/turf-monster.webp")))
    assert_nil EmailBrandReference.content_type_of("GIF89a....".b)
    assert_nil EmailBrandReference.content_type_of("<svg xmlns='http://www.w3.org/2000/svg'/>")
  end
end
