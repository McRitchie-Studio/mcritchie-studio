require "test_helper"

# THE PERSON PAGE'S LOOK ACTIONS ARE OPERATOR ACTIONS.
#
# Hub signup is open, so "logged in" is anyone with an email address. Before
# this gate a signed-up stranger could create a look for any person (its
# generation notes later feed a paid sheet build), move any person's default
# look, and file any URL at all as a look's newest character sheet, which the
# operator's browser then loaded and the chunk hand-off gave out as the swap
# reference.
class PeopleLookActionsGateTest < ActionDispatch::IntegrationTest
  SHEET = "https://cdn.example.com/sheets/test-look.png".freeze

  setup do
    @person = Person.create!(first_name: "Test", last_name: "Look Gated")
    @home = Appearance.create!(person_slug: @person.slug, descriptor: "Home Kit")
    @away = Appearance.create!(person_slug: @person.slug, descriptor: "Away Kit")
  end

  def create_look!(**params)
    post create_appearance_person_path(@person.slug, **params),
         params: { appearance: { descriptor: "Planted Look", generation_notes: "planted notes" } }
  end

  def make_default!(look = @away)
    post make_default_appearance_person_path(@person.slug), params: { appearance_slug: look.slug }
  end

  def attach!(url = SHEET, look: @home)
    post attach_artifact_person_path(@person.slug), params: { appearance_slug: look.slug, image_url: url }
  end

  def assert_nothing_written(&)
    assert_no_difference(["Appearance.count", "Artifact.count", "ArtifactSubject.count"], &)
    assert_equal @home.slug, @person.reload.default_appearance_slug
  end

  test "a visitor is sent to sign in by all three look actions" do
    assert_nothing_written do
      [-> { create_look! }, -> { make_default! }, -> { attach! }].each do |action|
        action.call
        assert_redirected_to "/login"
      end
    end
  end

  test "a non-admin cannot create a look for a person" do
    log_in_as users(:viewer)
    assert_nothing_written { create_look! }
    assert_redirected_to root_path
    assert_equal "Not authorized", flash[:alert]
  end

  test "a non-admin cannot change a person's default look" do
    log_in_as users(:viewer)
    assert_nothing_written { make_default! }
    assert_redirected_to root_path
    assert_equal "Not authorized", flash[:alert]
  end

  test "a non-admin cannot attach an image as a character sheet" do
    log_in_as users(:viewer)
    assert_nothing_written { attach! }
    assert_redirected_to root_path
    assert_equal "Not authorized", flash[:alert]
  end

  test "a non-admin cannot merge two people" do
    other = Person.create!(first_name: "Test", last_name: "Look Gatedd")
    log_in_as users(:viewer)
    assert_no_difference "Person.count" do
      post merge_people_path, params: { keep_slug: other.slug, merge_slug: @person.slug }
    end
    assert_redirected_to root_path
    assert_equal @person.slug, @home.reload.person_slug
  end

  test "the person page offers the look controls to an admin only" do
    controls = ["form[action='#{create_appearance_person_path(@person.slug)}']",
                "form[action='#{make_default_appearance_person_path(@person.slug)}']",
                "form[action='#{attach_artifact_person_path(@person.slug)}']",
                "details#new-model"]

    get person_path(@person.slug)
    assert_response :success
    assert_select "[data-test='default-look-badge']", 1
    controls.each { |control| assert_select control, 0 }

    log_in_as users(:viewer)
    get person_path(@person.slug)
    assert_response :success
    controls.each { |control| assert_select control, 0 }

    log_in_as users(:alex)
    get person_path(@person.slug)
    assert_select controls[0], 1
    assert_select controls[1], 1, "one Make default, for the look that is not the default"
    assert_select controls[2], 2, "one attach form per look"
    assert_select controls[3], 1
  end

  test "an admin creates a look, sets the default and attaches a sheet" do
    log_in_as users(:alex)

    assert_difference -> { @person.appearances.count } => 1 do
      post create_appearance_person_path(@person.slug), params: { appearance: { descriptor: "Third Kit" } }
    end
    assert_redirected_to person_path(@person.slug)
    assert_match "Third Kit saved", flash[:notice]

    make_default!
    assert_redirected_to person_path(@person.slug)
    assert_equal @away.slug, @person.reload.default_appearance_slug

    assert_difference ["Artifact.count", "ArtifactSubject.count"], 1 do
      attach!("  #{SHEET} ", look: @away)
    end
    assert_redirected_to person_path(@person.slug)
    assert_match "Model image attached to Away Kit", flash[:notice]
    artifact = Artifact.find_by!(image_url: SHEET)
    assert_equal ["character_sheet", "operator"], artifact.values_at(:kind, :source)
    assert_equal [[@person.slug, @away.slug]], artifact.subjects.pluck(:person_slug, :appearance_slug)
  end

  test "an admin's look form still returns to the cast card it came from" do
    log_in_as users(:alex)
    card = "/music_videos/test-video#person-1"
    post create_appearance_person_path(@person.slug, return_to: card), params: { appearance: { descriptor: "Card Kit" } }
    assert_redirected_to card
  end

  test "an admin's refused image URL files nothing and says why" do
    log_in_as users(:alex)
    ["javascript:alert(1)", "data:image/png;base64,QUJD", "file:///etc/passwd", "http://cdn.example.com/a.png",
     "https://localhost/a.png", "https://127.0.0.1/a.png", "https://10.0.0.5/a.png", "https://169.254.169.254/latest",
     "https://[::1]/a.png", "https://hub.internal/a.png", "/uploads/a.png", "//cdn.example.com/a.png", "not a url", ""].each do |url|
      # A refused URL is an answer, not an error: no ErrorLog row either.
      assert_no_difference("ErrorLog.count") { assert_nothing_written { attach!(url) } }
      assert_redirected_to person_path(@person.slug)
      assert_equal Appearances::FetchableUrl::HTTPS_REFUSAL, flash[:alert], "refusing #{url.inspect}"
      assert_no_match(/attached/, flash[:notice].to_s)
    end
  end
end
