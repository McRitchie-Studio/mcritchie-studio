# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [integration] /email_images/generator through the routes: admin only on both
# pages; the character branch (Turf Monster's canonical sheet and his name in
# the prompt) and the no-character branch (the kit's references and "the
# brand's mascot/mark"); an unknown kit is a 404; the links in from
# /email_images and the brand kit page. Writes nothing, calls no generator.
class EmailImageGeneratorsControllerTest < ActionDispatch::IntegrationTest
  include EmailImageFakes

  setup do
    AppearanceReferencePhoto.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    EmailImageBrief.delete_all
    EmailBrandReference.delete_all
    Appearance.where.not(character_slug: nil).delete_all
    Character.delete_all
  end

  test "an anonymous visitor reaches neither page" do
    get email_image_generators_path
    assert_response :redirect
    get email_image_generator_path("turf-monster")
    assert_response :redirect
  end

  test "a signed-in non-admin is denied on both pages" do
    routed = Rails.application.routes.routes.filter_map do |r|
      r.defaults[:action] if r.defaults[:controller] == "email_image_generators"
    end
    assert_equal %w[index show], routed.uniq.sort, "every routed action is covered here"
    log_in_as(users(:viewer))

    get email_image_generators_path
    assert_not_equal 200, response.status
    get email_image_generator_path("turf-monster")
    assert_not_equal 200, response.status
    assert_no_match(/Run the email-image SOP/, response.body)
  end

  test "the character branch: Turf Monster's canonical sheet, his link and his name in the prompt" do
    character = Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster")
    look = character.appearances.create!(descriptor: "Classic")
    AppearanceReferencePhoto.create!(appearance_slug: look.slug, source: "upload", chosen: true, title: "Kit mascot",
                                     image_url: "https://assets.example.test/mascot.png", created_at: 1.day.ago)
    AppearanceReferencePhoto.create!(appearance_slug: look.slug, source: "upload", chosen: true,
                                     title: "Canonical sheet v3 (white jersey, pads, no helmet) - approved by Alex 2026-10-07",
                                     image_url: "https://assets.example.test/canonical.png")
    log_in_as(users(:alex))

    assert_no_difference -> { Artifact.count + EmailImageBrief.count + AppearanceReferencePhoto.count } do
      get email_image_generator_path("turf-monster")
    end
    assert_response :success
    assert_select "a[data-test='character-link'][href='/characters/turf-monster']", "Turf Monster"
    assert_select "[data-test='model-image'] img[src='https://assets.example.test/canonical.png']"
    assert_select "textarea[data-test='prompt']", /Look: Turf Monster in his canonical look, on-brand pose\./
    assert_select "[data-test='example'][data-source='kit style anchor']"
  end

  test "the no-character branch: the kit's references and the brand's mark in the prompt" do
    log_in_as(users(:alex))
    get email_image_generator_path("mcritchie-studio")

    assert_response :success
    assert_select "[data-test='character-model']", 0
    assert_select "[data-test='kit-model'] [data-test='kit-reference'] img[src='/favicon.png']"
    assert_select "textarea[data-test='prompt']", /Brand: mcritchie-studio .*the brand's mascot\/mark/m
  end

  test "an unknown kit is a 404" do
    log_in_as(users(:alex))
    get email_image_generator_path("no-such-kit")
    assert_response :not_found
  end

  test "the kit list links every kit, and /email_images and the brand kit page link in" do
    Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster")
    log_in_as(users(:alex))

    get email_image_generators_path
    assert_response :success
    EmailImages::BrandKit.keys.each do |key|
      assert_select "[data-test='generator-kit'][data-kit='#{key}'] a[href='/email_images/generator/#{key}']"
    end
    assert_select "[data-test='generator-kit'][data-kit='turf-monster']", /model: Turf Monster/

    get email_images_path
    assert_select "a[data-test='generator-link'][href='/email_images/generator']", "Email image generator"
    get email_brand_kit_path("turf-monster")
    assert_select "a[data-test='generator-link'][href='/email_images/generator/turf-monster']"
  end
end
