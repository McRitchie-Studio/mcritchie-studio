# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [integration] /email_images/brand_kits through the routes: admin only on
# every action, an upload is stored (the store is stubbed: no bucket) and then
# listed on the kit page, archive drops it from what a round sends, and a bad
# file re-renders with its error and stores nothing.
class EmailBrandKitsControllerTest < ActionDispatch::IntegrationTest
  include EmailImageFakes

  setup do
    Artifact.where(kind: "email_header").delete_all
    EmailImageBrief.delete_all
    EmailBrandReference.delete_all
    @admin = users(:alex)
    @viewer = users(:viewer)
  end

  def with_recording_store(&block)
    stored = []
    store = lambda do |source, prefix:, subject:, **|
      stored << { source: source, prefix: prefix, subject: subject }
      "https://assets.example.test/#{prefix}/#{subject}/#{stored.size}.png"
    end
    Appearances::StoreGeneratedImage.stub(:call, store) { block.call(stored) }
  end

  def upload_params(file, **overrides)
    { email_brand_reference: { file: file, role: "mascot", label: "Gator wave", note: "use this pose" }.merge(overrides) }
  end

  test "an anonymous visitor reaches nothing" do
    get email_brand_kits_path
    assert_response :redirect
    get email_brand_kit_path("turf-monster")
    assert_response :redirect
  end

  # EVERY ROUTED ACTION, reads included: a non-admin reaches none of them,
  # nothing is stored and nothing is archived.
  test "a signed-in non-admin is denied on every action" do
    ref = brand_reference
    log_in_as(@viewer)

    with_recording_store do |stored|
      requests = {
        index: -> { get email_brand_kits_path },
        show: -> { get email_brand_kit_path("turf-monster") },
        create_reference: -> { post email_brand_kit_references_path("turf-monster"), params: upload_params(uploaded(EmailImageFakes.small_png, name: "a.png")) },
        archive_reference: -> { post archive_email_brand_kit_reference_path("turf-monster", ref.slug) }
      }
      routed = Rails.application.routes.routes.filter_map { |r| r.defaults[:action] if r.defaults[:controller] == "email_brand_kits" }
      assert_equal routed.map(&:to_sym).uniq.sort, requests.keys.sort, "every routed action is covered here"

      requests.each do |action, request|
        request.call
        assert_not_equal 200, response.status, "#{action} answered 200 to a non-admin"
        assert_no_match(/Gator wave|turf-monster-style-anchor/, response.body.to_s, "#{action} leaked the kit")
      end
      assert_empty stored
    end
    assert_equal 1, EmailBrandReference.count
    assert_nil ref.reload.archived_at
  end

  test "an admin sees every kit on the index, linked from /email_images" do
    log_in_as(@admin)
    get email_images_path
    assert_select "[data-test='brand-kits-link'][href=?]", email_brand_kits_path

    get email_brand_kits_path
    assert_response :success
    assert_select "[data-test='brand-kit-card']", 3
    assert_select "[data-test='brand-kit-card'][data-kit='turf-monster'][href=?]", email_brand_kit_path("turf-monster")
  end

  test "an unknown kit is a 404" do
    log_in_as(@admin)
    get email_brand_kit_path("acme")
    assert_response :not_found
  end

  test "an admin uploads a PNG: it is stored under email_brand/<kit>/refs and listed on the kit page" do
    log_in_as(@admin)

    with_recording_store do |stored|
      post email_brand_kit_references_path("turf-monster"),
           params: upload_params(uploaded(EmailImageFakes.small_png, name: "gator.png"))

      assert_redirected_to email_brand_kit_path("turf-monster")
      assert_equal [["email_brand", "turf-monster/refs"]], stored.map { |s| s.values_at(:prefix, :subject) }
    end
    ref = EmailBrandReference.sole
    assert_equal ["turf-monster", "mascot", "Gator wave", "use this pose", @admin.email],
                 ref.values_at(:brand_kit, :role, :label, :note, :uploaded_by)

    follow_redirect!
    assert_select "[data-test='reference'][data-origin='upload']", 1 do
      assert_select "img[src=?]", ref.image_url
      assert_select "[data-test='reference-label']", "Gator wave"
      assert_select "[data-test='reference-note']", /use this pose/
      assert_select "[data-test='sent-badge']", "sent #3"
    end
  end

  test "a text file named .png is refused, re-rendered with its error, and nothing is stored" do
    log_in_as(@admin)

    with_recording_store do |stored|
      post email_brand_kit_references_path("turf-monster"), params: upload_params(uploaded("hello", name: "logo.png"))

      assert_response :unprocessable_content
      assert_select "[data-test='form-errors']", /PNG, JPEG or WebP/
      assert_empty stored
    end
    assert_equal 0, EmailBrandReference.count
  end

  test "archive drops a reference from the page's list and from what a round sends" do
    ref = brand_reference(label: "Retired pose")
    log_in_as(@admin)

    post archive_email_brand_kit_reference_path("turf-monster", ref.slug)
    assert_redirected_to email_brand_kit_path("turf-monster")
    assert_predicate ref.reload, :archived?
    assert_not_includes EmailImages::BrandKit.find!("turf-monster").generator_references.map(&:label), "Retired pose"

    follow_redirect!
    assert_select "[data-test='reference'][data-origin='upload']", 0
    assert_select "[data-test='archived-references']", /Retired pose/
  end

  test "a reference cannot be archived through another kit's URL" do
    ref = brand_reference
    log_in_as(@admin)
    post archive_email_brand_kit_reference_path("mcritchie-studio", ref.slug)
    assert_response :not_found
    assert_nil ref.reload.archived_at
  end
end
