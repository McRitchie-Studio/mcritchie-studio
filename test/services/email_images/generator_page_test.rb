# frozen_string_literal: true

require "test_helper"
require_relative "../../support/email_image_fakes"

# [unit] What the generator page picks: the model image in Alex's order
# (canonical sheet reference, else the newest approved character sheet, else
# the look's first reference), and up to four examples (approved headers
# first, then the kit's style anchor).
class EmailImages::GeneratorPageTest < ActiveSupport::TestCase
  include EmailImageFakes

  setup do
    AppearanceReferencePhoto.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    EmailImageBrief.delete_all
    EmailBrandReference.delete_all
    Appearance.where.not(character_slug: nil).delete_all
    Character.delete_all
    @kit = EmailImages::BrandKit.find!("turf-monster")
  end

  def turf_character
    @character = Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster")
    @look = @character.appearances.create!(descriptor: "Classic")
    @character.reload
  end

  def photo(title, at: Time.current, chosen: true)
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, source: "upload", chosen: chosen, title: title,
                                     image_url: "https://assets.example.test/#{title.parameterize}.png", created_at: at)
  end

  def sheet(approved:, at: Time.current)
    art = Artifact.create!(kind: "character_sheet", image_url: "https://assets.example.test/sheet-#{at.to_i}.png",
                           approved_at: (at if approved), created_at: at)
    ArtifactSubject.create!(artifact_slug: art.slug, character_slug: @character.slug, appearance_slug: @look.slug)
    art
  end

  def page = EmailImages::GeneratorPage.new(@kit)

  test "the newest reference titled Canonical sheet wins over sheets and other art" do
    turf_character
    photo("Kit mascot", at: 3.days.ago)
    photo("Canonical sheet v2", at: 2.days.ago)
    photo("Canonical sheet v3 (white jersey, pads, no helmet) - approved by Alex 2026-10-07", at: 1.day.ago)
    photo("Canonical sheet v4 rejected", chosen: false)
    sheet(approved: true)

    image = page.model_image
    assert_equal "https://assets.example.test/canonical-sheet-v3-white-jersey-pads-no-helmet-approved-by-alex-2026-10-07.png", image.url
    assert_match(/\ACanonical sheet v3/, image.label)
    assert_equal "Turf Monster", page.character.name
    assert_equal "Classic", page.look.descriptor
  end

  test "without a canonical reference, the newest approved character sheet; an unapproved one never" do
    turf_character
    photo("Kit mascot")
    older = sheet(approved: true, at: 2.days.ago)
    sheet(approved: false, at: 1.hour.ago)

    assert_equal older.image_url, page.model_image.url
    assert_equal "Approved character sheet", page.model_image.label
  end

  test "with neither, the look's first reference; with no art at all, nothing" do
    turf_character
    assert_nil page.model_image

    photo("Kit mascot", at: 2.days.ago)
    photo("Kit style anchor", at: 1.day.ago)
    assert_equal "Kit mascot", page.model_image.label
  end

  test "a kit no live character fronts has no character and a mark prompt" do
    Character.create!(name: "Old Gator", kind: "mascot", brand: "turf-monster", retired_at: Time.current)
    studio = EmailImages::GeneratorPage.new(EmailImages::BrandKit.find!("mcritchie-studio"))

    assert_not page.character?
    assert_nil page.model_image
    assert_includes studio.prompt, "the brand's mascot/mark"
    assert_includes studio.prompt_template, "{{headline}}"
  end

  test "examples: approved headers newest first, then the style anchor, at most four, each labelled" do
    5.times do |i|
      brief = turf_brief(email_key: "email_#{i}", headline: "Headline #{i}")
      art = Artifact.create!(kind: "email_header", brief_slug: brief.slug, image_url: "https://assets.example.test/h#{i}.jpg")
      brief.approve!(art, by: "alex")
      art.update_columns(approved_at: i.hours.ago)
    end
    turf_brief(email_key: "unapproved")

    examples = page.examples
    assert_equal 4, examples.size
    assert_equal %w[h0 h1 h2 h3], examples.map { |e| File.basename(e.url, ".jpg") }
    assert_equal "email_0_new_player: “Headline 0”", examples.first.label
    assert(examples.all? { |e| e.source == "approved header" })
  end

  test "with no approved header the examples are the kit's style anchor" do
    examples = page.examples

    assert_equal ["/email_brand/turf-monster-style-anchor.jpg"], examples.map(&:url)
    assert_equal "kit style anchor", examples.first.source
    assert_match(/\AStyle anchor/, examples.first.label)
  end
end
