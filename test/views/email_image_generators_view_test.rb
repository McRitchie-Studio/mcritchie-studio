# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [component] The generator page's sections, rendered alone from the page
# object the controller sets: the character model (or the kit's references),
# the examples, and the copy box with its inputs, textarea, Copy button, the
# template handed to Alpine and the CLI hint; and the kit list.
class EmailImageGeneratorsViewTest < ActionView::TestCase
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

  def render_page(key)
    @page = EmailImages::GeneratorPage.new(EmailImages::BrandKit.find!(key))
    render template: "email_image_generators/show"
  end

  def turf_with_canonical_sheet
    character = Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster")
    look = character.appearances.create!(descriptor: "Classic")
    AppearanceReferencePhoto.create!(appearance_slug: look.slug, source: "upload", chosen: true,
                                     title: "Canonical sheet v3 (white jersey, pads, no helmet) - approved by Alex 2026-10-07",
                                     image_url: "https://assets.example.test/canonical.png")
  end

  test "a character kit shows the model: name linked to the character, the look, the canonical sheet large" do
    turf_with_canonical_sheet
    render_page("turf-monster")

    assert_select "[data-test='character-model']" do
      assert_select "a[data-test='character-link'][href='/characters/turf-monster']", "Turf Monster"
      assert_select "[data-test='model-look']", "Classic"
      assert_select "[data-test='model-image'] img[src='https://assets.example.test/canonical.png']"
      assert_select "[data-test='model-caption']", /\ACanonical sheet v3/
    end
    assert_select "[data-test='kit-model']", 0
  end

  test "a character with no art says so and links his page" do
    Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster").appearances.create!(descriptor: "Classic")
    render_page("turf-monster")

    assert_select "[data-test='model-image']", 0
    assert_select "[data-test='model-missing'] a[href='/characters/turf-monster']"
  end

  test "a kit with no character shows the kit's references instead" do
    render_page("mcritchie-industries")

    assert_select "[data-test='character-model']", 0
    assert_select "[data-test='kit-model'] [data-test='kit-reference'][data-role='logo'] img[src='/email_brand/mcritchie-industries-icon.png']"
    assert_select "textarea[data-test='prompt']", /the brand's mascot\/mark, on-brand pose\./
  end

  test "the examples show approved headers and the style anchor, labelled" do
    brief = turf_brief
    art = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/h.jpg")
    brief.approve!(art, by: "alex")
    render_page("turf-monster")

    assert_select "[data-test='example']", 2
    assert_select "[data-test='example'][data-source='approved header'] img[src='https://assets.example.test/h.jpg']"
    assert_select "[data-test='example'][data-source='approved header'] [data-test='example-label']",
                  "drop_signup_confirmation_new_player: “You're In!”"
    assert_select "[data-test='example'][data-source='kit style anchor'] img[src='/email_brand/turf-monster-style-anchor.jpg']"
  end

  test "the copy box has the three inputs, the default prompt, the Copy button, Alpine's template and the CLI hint" do
    turf_with_canonical_sheet
    render_page("turf-monster")

    assert_select "[data-test='copy-box']" do
      assert_select "input[data-test='input-email'][x-model='email']"
      assert_select "input[data-test='input-headline'][x-model='headline']"
      assert_select "input[data-test='input-mood'][x-model='mood']"
      assert_select "textarea[data-test='prompt'][readonly]",
                    EmailImages::GeneratorPrompt.call(kit_key: "turf-monster", character_name: "Turf Monster")
      assert_select "button[data-test='copy-prompt']", "Copy"
      assert_select "[data-test='cli-hint']", "bin/email-image assets turf-monster"
    end
    x_data = css_select("[data-test='copy-box']").first["x-data"]
    assert_includes x_data, EmailImages::GeneratorPrompt.template_for(kit_key: "turf-monster", character_name: "Turf Monster").to_json
    assert_select "a[data-test='brand-kit-link'][href='/email_images/brand_kits/turf-monster']"
  end

  test "the kit list links every kit and names its character" do
    Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster")
    @kits = EmailImages::BrandKit.all
    @characters = { "turf-monster" => Character.first }
    render template: "email_image_generators/index"

    assert_select "[data-test='generator-kit']", @kits.size
    assert_select "[data-test='generator-kit'][data-kit='turf-monster'] a[href='/email_images/generator/turf-monster']", /model: Turf Monster/
    assert_select "[data-test='generator-kit'][data-kit='mcritchie-studio']", /no character/
  end
end
