# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [integration] A character's look runs the sheet build end to end with the
# fake generator (no paid call, no bucket) and files a subject row under the
# character; and every person-only feature leaves character looks out: the
# model pipeline board, the recast pickers, the people index's model
# thumbnails, the identity mint, the iced twin and the likeness search.
class CharacterLooksTest < ActionDispatch::IntegrationTest
  include EmailImageFakes

  setup do
    AppearanceReferencePhoto.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    Appearance.delete_all
    Character.delete_all
    ImageGeneration::Registry.reload!
    @character = Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster")
    @look = @character.appearances.create!(descriptor: "Classic", generation_notes: "Green gator.")
    @art = "https://assets.example.test/characters/turf-monster/refs/1.webp"
    AppearanceReferencePhoto.create!(appearance_slug: @look.slug, source: "upload", chosen: true, image_url: @art)
    @person = people(:josh_allen)
    @person_look = Appearance.create!(person_slug: @person.slug, descriptor: "Bills home")
  end

  teardown { ImageGeneration::Registry.reload! }

  test "the sheet build runs for a character look and files the sheet under the character" do
    stored = []
    store = lambda do |_source, subject: nil, prefix: Appearances::StoreGeneratedImage::PREFIX, **|
      stored << { prefix: prefix, subject: subject }
      "https://assets.example.test/#{prefix}/#{subject}/sheet.png"
    end
    EmailImageFakes::Adapter.reset!
    ImageGeneration::Adapter.stub(:for, EmailImageFakes::Adapter) do
      Appearances::StoreGeneratedImage.stub(:call, store) do
        with_env("OPENAI_API_KEY", "sk-test") { build_and_check(stored) }
      end
    end
    check_filed
  end

  def build_and_check(stored)
    started_at = Appearances::SheetBuild.start!(@look)
    Appearances::SheetBuild.run(@look.reload, started_at: started_at)

    assert_equal "done", @look.reload.sheet_build_state, @look.sheet_build_error
    call = EmailImageFakes::Adapter.calls.sole
    assert_equal [@art], call[:reference_urls]
    assert_includes call[:prompt], "Turf Monster, an original illustrated mascot"
    assert_no_match(/this exact man|photograph/i, call[:prompt])
    assert_equal [{ prefix: "character-sheets", subject: "characters/turf-monster" }], stored
  end

  def check_filed
    artifact = Artifact.sole
    subject = artifact.subjects.sole
    assert_equal ["character_sheet", "turf-monster", nil, @look.slug],
                 [artifact.kind, subject.character_slug, subject.person_slug, subject.appearance_slug]
    assert_equal [artifact], @character.artifacts.to_a
    assert_equal({ @look.slug => artifact }, Artifact.newest_character_sheets([@look.slug]))

    log_in_as(users(:alex))
    get character_path(@character)
    assert_select "[data-test='character-artifact'][data-artifact='#{artifact.slug}']"
    assert_select "[data-test='look-sheet'] img"
  end

  test "the model pipeline board lists person looks only and will not move a character look" do
    board = Appearances::Pipeline.build
    slugs = board[:lanes].flat_map { |lane| lane.cards.map { |c| c.appearance.slug } }
    assert_includes slugs, @person_look.slug
    assert_not_includes slugs, @look.slug
    assert_equal 0, board[:orphan_count]

    log_in_as(users(:alex))
    patch model_pipeline_look_path(@look.slug), params: { appearance: { stage: "defined" } }, as: :json
    assert_response :not_found
  end

  test "the recast pickers never offer a character look" do
    options = MusicVideos::LookOptions.for([@person.slug])
    offered = options.values.flatten.map { |o| o.respond_to?(:slug) ? o.slug : o[:slug] }
    assert_not_includes offered, @look.slug
    assert_not Appearance.recastable.exists?(slug: @look.slug)
  end

  test "the people index's model thumbnails skip a character's sheet" do
    artifact = Artifact.create!(kind: "character_sheet", image_url: "https://assets.example.test/x.png")
    ArtifactSubject.create!(artifact_slug: artifact.slug, character_slug: @character.slug, appearance_slug: @look.slug)

    log_in_as(users(:alex))
    get people_path
    assert_response :success
    assert_no_match(%r{assets\.example\.test/x\.png}, response.body)
  end

  test "no identity, twin or likeness search runs for a character look" do
    error = assert_raises(Appearances::CreateCharacterReference::NoReferenceImages) do
      Appearances::CreateCharacterReference.new(@look, client: Object.new).call
    end
    assert_match(/one of our characters/, error.message)
    assert_nil @look.reload.higgsfield_reference_id

    assert_match(/no iced twin/, Appearances::IcedTwin.refusal(@look))
    assert_raises(Appearances::IcedTwin::Refused) { Appearances::IcedTwin.create!(@look) }

    search = Class.new do
      def self.available? = true
      def self.provider_name = "fake"
      def self.call(*) = raise("searched for a character")
    end
    summary = Appearances::GatherReferencePhotos.call(@look, search: search)
    assert_equal 0, summary.returned
  end
end
