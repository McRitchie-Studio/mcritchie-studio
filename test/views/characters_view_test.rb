# frozen_string_literal: true

require "test_helper"

# [component] The cast card and the character profile, rendered alone from
# their locals; and the brand kit page's "Featured character" link.
class CharactersViewTest < ActionView::TestCase
  setup do
    Appearance.where.not(character_slug: nil).delete_all
    Character.delete_all
    @character = Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster",
                                   bio: "The gator.", personality: "Loud.", voice_notes: "Short lines.")
  end

  test "the cast card shows avatar, name, kind, brand and the look count, and links the profile" do
    render partial: "characters/cast_card",
           locals: { character: @character, avatar_url: "/agents/turf-monster.webp", look_count: 2 }

    assert_select "a[data-test='cast-card'][href='/characters/turf-monster']" do
      assert_select "img[data-test='cast-avatar'][src='/agents/turf-monster.webp'][alt='Turf Monster']"
      assert_select "[data-test='cast-name']", "Turf Monster"
      assert_select "[data-test='cast-kind']", "mascot"
      assert_select "[data-test='cast-brand']", "turf-monster"
      assert_select "[data-test='cast-looks']", "2 looks"
    end
  end

  test "a cast card with no avatar and no brand shows an initial and no brand chip" do
    puppet = Character.create!(name: "Sock", kind: "puppet")
    render partial: "characters/cast_card", locals: { character: puppet, avatar_url: nil, look_count: 0 }

    assert_select "[data-test='cast-avatar']", 0
    assert_select "[data-test='cast-brand']", 0
    assert_select "[data-test='cast-looks']", "0 looks"
  end

  test "the profile shows bio, personality, voice notes and links the brand kit" do
    render partial: "characters/profile",
           locals: { character: @character, kit: @character.brand_kit, avatar_url: "/agents/turf-monster.webp" }

    assert_select "[data-test='character-profile'] h1", "Turf Monster"
    assert_select "[data-test='profile-kind']", "mascot"
    assert_select "[data-test='profile-bio'] dd", "The gator."
    assert_select "[data-test='profile-personality'] dd", "Loud."
    assert_select "[data-test='profile-voice'] dd", "Short lines."
    assert_select "a[data-test='profile-brand-kit'][href='/email_images/brand_kits/turf-monster']", /Turf Monster/
    assert_select "a[data-test='edit-character'][href='/characters/turf-monster/edit']"
  end

  test "a look card shows its art, default badge and sheet state" do
    look = @character.appearances.create!(descriptor: "Classic")
    art = AppearanceReferencePhoto.create!(appearance_slug: look.slug, source: "upload", chosen: true,
                                           title: "Kit mascot", image_url: "https://assets.example.test/a.webp")
    render partial: "characters/look", locals: { character: @character, look: look, art: [art], sheet: nil }

    assert_select "[data-test='look-name']", "Classic"
    assert_select "[data-test='look-default']", "default"
    assert_select "[data-test='look-sheet-state']", /none yet/
    assert_select "[data-test='look-art'] img[src='https://assets.example.test/a.webp']"
    assert_select "[data-test='build-sheet-form']"
    assert_select "[data-test='make-default-form']", 0
  end

  test "the brand kit page links its featured character, and only when one is live" do
    render_kit(featured: Character.featured_for("turf-monster"))
    assert_select "a[data-test='featured-character'][href='/characters/turf-monster']", "Featured character: Turf Monster →"

    @character.update!(retired_at: Time.current)
    render_kit(featured: Character.featured_for("turf-monster"))
    assert_select "[data-test='featured-character']", 0
  end

  private

  # Sets the ivars EmailBrandKitsController#load_show sets; @rendered is reset so
  # each call's assertions read only that render.
  def render_kit(featured:)
    @kit = EmailImages::BrandKit.find!("turf-monster")
    @featured_character = featured
    @references = @kit.references
    @generator_row = ImageGeneration::Registry.find("openai_image_header")
    @reference_limit = 4
    @sent = @kit.generator_references(limit: 4)
    @archived = []
    @approved_headers = []
    @open_briefs = []
    @reference = EmailBrandReference.new(brand_kit: @kit.key, role: "mascot")
    @rendered = render(template: "email_brand_kits/show")
  end
end
