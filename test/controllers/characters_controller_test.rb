# frozen_string_literal: true

require "test_helper"
require_relative "../support/email_image_fakes"

# [integration] /characters through the routes: admin only on every action;
# an admin creates a character, adds a look with art (the store is stubbed: no
# bucket), makes a look the default, and starts a sheet build that claims the
# character's look (no job runs, nothing is bought).
class CharactersControllerTest < ActionDispatch::IntegrationTest
  include EmailImageFakes

  setup do
    AppearanceReferencePhoto.delete_all
    ArtifactSubject.delete_all
    Artifact.delete_all
    Appearance.where.not(character_slug: nil).delete_all
    Character.delete_all
    @admin = users(:alex)
    @viewer = users(:viewer)
    @character = Character.create!(name: "Turf Monster", kind: "mascot", brand: "turf-monster", bio: "The gator.")
    @look = @character.appearances.create!(descriptor: "Classic")
  end

  def with_recording_store(&block)
    stored = []
    store = lambda do |source, prefix:, subject:, **|
      stored << { prefix: prefix, subject: subject }
      "https://assets.example.test/#{prefix}/#{subject}/#{stored.size}.png"
    end
    Appearances::StoreGeneratedImage.stub(:call, store) { block.call(stored) }
  end

  test "an anonymous visitor reaches nothing" do
    get characters_path
    assert_response :redirect
    get character_path(@character)
    assert_response :redirect
  end

  test "a signed-in non-admin is denied on every action and nothing changes" do
    log_in_as(@viewer)
    png = uploaded(EmailImageFakes.small_png, name: "a.png")

    with_recording_store do |stored|
      requests = {
        index: -> { get characters_path },
        show: -> { get character_path(@character) },
        new: -> { get new_character_path },
        create: -> { post characters_path, params: { character: { name: "Sock", kind: "puppet" } } },
        edit: -> { get edit_character_path(@character) },
        update: -> { patch character_path(@character), params: { character: { name: "Hacked" } } },
        create_look: -> { post looks_character_path(@character), params: { appearance: { descriptor: "Evil" } } },
        upload_art: -> { post character_look_art_path(@character, @look.slug), params: { art: png } },
        make_default: -> { post default_character_look_path(@character, @look.slug) },
        build_sheet: -> { post character_look_sheet_path(@character, @look.slug) }
      }
      routed = Rails.application.routes.routes.filter_map { |r| r.defaults[:action] if r.defaults[:controller] == "characters" }
      assert_equal routed.map(&:to_sym).uniq.sort, requests.keys.sort, "every routed action is covered here"

      requests.each do |action, request|
        request.call
        assert_not_equal 200, response.status, "#{action} answered 200 to a non-admin"
        assert_no_match(/The gator\./, response.body.to_s, "#{action} leaked the profile")
      end
      assert_empty stored
    end
    assert_equal 1, Character.count
    assert_equal "Turf Monster", @character.reload.name
    assert_equal 1, Appearance.where(character_slug: @character.slug).count
    assert_nil @look.reload.sheet_build_state
  end

  test "an admin sees the cast and the profile" do
    log_in_as(@admin)
    get characters_path
    assert_response :success
    assert_select "[data-test='cast-card'][data-character='turf-monster'] [data-test='cast-looks']", "1 look"

    get character_path(@character)
    assert_response :success
    assert_select "[data-test='character-look'][data-look='#{@look.slug}'] [data-test='look-default']"
    assert_select "[data-test='profile-brand-kit'][href='#{email_brand_kit_path('turf-monster')}']"
  end

  test "an admin creates a character, then a look with its art" do
    log_in_as(@admin)
    post characters_path, params: { character: { name: "Sock Puppet", kind: "puppet", bio: "Knitted." } }
    sock = Character.find_by!(slug: "sock-puppet")
    assert_redirected_to character_path(sock)

    with_recording_store do |stored|
      post looks_character_path(sock), params: { appearance: {
        descriptor: "Striped", colorway: "red", generation_notes: "Red and white stripes.",
        art: uploaded(EmailImageFakes.small_png, name: "sock.png"), art_label: "Front"
      } }
      assert_redirected_to character_path(sock)
      assert_equal [{ prefix: "characters", subject: "sock-puppet/refs" }], stored
    end

    look = sock.appearances.sole
    assert_equal %w[Striped red], [look.descriptor, look.colorway]
    assert_nil look.person_slug
    assert_equal look.slug, sock.reload.default_appearance_slug
    art = AppearanceReferencePhoto.where(appearance_slug: look.slug).sole
    assert_equal ["upload", true, "Front", "image/png"], [art.source, art.chosen, art.title, art.mime_type]
  end

  test "a bad look re-renders with its error; bad art is refused and stores nothing" do
    log_in_as(@admin)
    post looks_character_path(@character), params: { appearance: { descriptor: "" } }
    assert_response :unprocessable_content

    with_recording_store do |stored|
      post character_look_art_path(@character, @look.slug),
           params: { art: uploaded("not an image", name: "fake.png", type: "image/png") }
      assert_redirected_to character_path(@character)
      assert_match(/PNG, JPEG or WebP/, flash[:alert])
      assert_empty stored
    end
    assert_equal 0, AppearanceReferencePhoto.count
  end

  test "an admin edits, makes a look default, and retires a character" do
    log_in_as(@admin)
    holiday = @character.appearances.create!(descriptor: "Holiday")
    post default_character_look_path(@character, holiday.slug)
    assert_equal holiday.slug, @character.reload.default_appearance_slug

    patch character_path(@character), params: { character: { personality: "Loud.", retired: "1" } }
    assert_redirected_to character_path(@character)
    assert_equal "Loud.", @character.reload.personality
    assert @character.retired?
    get characters_path
    assert_select "[data-test='cast-card']", 0
  end

  test "build sheet claims the character's look; with no art it refuses free" do
    log_in_as(@admin)
    with_env("OPENAI_API_KEY", "sk-test") do
      post character_look_sheet_path(@character, @look.slug)
      assert_match(/Turf Monster cannot be built: no reference art/, flash[:alert])
      assert_nil @look.reload.sheet_build_state

      AppearanceReferencePhoto.create!(appearance_slug: @look.slug, source: "upload", chosen: true,
                                       image_url: "https://assets.example.test/characters/turf-monster/refs/1.png")
      assert_enqueued_with(job: SheetBuildJob) do
        post character_look_sheet_path(@character, @look.slug)
      end
      assert_equal Appearances::SheetBuild::STARTED_NOTICE, flash[:notice]
      assert_equal "building", @look.reload.sheet_build_state
    end
  end
end
