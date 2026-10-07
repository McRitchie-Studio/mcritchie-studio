require "test_helper"
require Rails.root.join("db/seeds/data/lettered_video.rb").to_s

# [integration] A look's jersey number (piece 16): typed when a look is made
# (the person page, the cast card's Generate a new look), kept when a sheet is
# generated with one, taken from the athlete's roster number when none is
# typed, and edited on the person page, where saving refills the stored clip
# prompts. Admin only. Synthetic people.
class LookJerseyNumberTest < ActionDispatch::IntegrationTest
  setup do
    @person = Person.create!(first_name: "Test", last_name: "Jersey Omega", athlete: true)
  end

  test "a non-admin cannot edit a look's number" do
    look = @person.appearances.create!(descriptor: "Home White")
    log_in_as users(:viewer)
    patch update_appearance_person_path(@person.slug), params: { appearance_slug: look.slug, appearance: { jersey_number: "9" } }

    assert_redirected_to root_path
    assert_nil look.reload.jersey_number
  end

  test "the person page makes a look with a number, edits it, and clears it" do
    log_in_as users(:alex)
    post create_appearance_person_path(@person.slug), params: { appearance: { descriptor: "Home White", jersey_number: "04" } }
    look = @person.appearances.live.find_by!(descriptor: "Home White")
    assert_equal 4, look.jersey_number

    get person_path(@person.slug)
    assert_select "[data-test='look-jersey']", "#4"
    assert_select "[data-test='look-jersey-form'] input[name='appearance[jersey_number]'][value='4']"

    patch update_appearance_person_path(@person.slug), params: { appearance_slug: look.slug, appearance: { jersey_number: "88" } }
    assert_redirected_to person_path(@person.slug)
    assert_equal "Home White: wears #88.", flash[:notice]
    assert_equal 88, look.reload.jersey_number

    patch update_appearance_person_path(@person.slug), params: { appearance_slug: look.slug, appearance: { jersey_number: "" } }
    assert_nil look.reload.jersey_number

    patch update_appearance_person_path(@person.slug), params: { appearance_slug: look.slug, appearance: { jersey_number: "100" } }
    assert_match(/Jersey number/, flash[:alert])
    assert_nil look.reload.jersey_number
  end

  test "saving a number refills the stored prompts of a source that casts the look" do
    video = LetteredVideo.seed!
    performer = video.video_performers.find_by!(ordinal: 2)
    look = Appearance.find_by!(slug: performer.recast_appearance_slug)
    log_in_as users(:alex)

    patch update_appearance_person_path(look.person_slug), params: { appearance_slug: look.slug, appearance: { jersey_number: "12" } }

    assert_includes video.video_chunks.find_by!(ordinal: 3).prompt, "Person B (lead) -> #12 Test Passer Epsilon"
  end

  test "a new look wears the athlete's roster number unless one is typed" do
    Athlete.create!(person_slug: @person.slug, sport: "football", jersey_number: 18)
    assert_equal 18, @person.appearances.create!(descriptor: "Home Purple").jersey_number
    assert_equal 7, @person.appearances.create!(descriptor: "Throwback", jersey_number: 7).jersey_number
  end

  test "a number outside 0-99 is refused" do
    look = @person.appearances.new(descriptor: "Odd", jersey_number: 100)
    assert_not look.valid?
    assert_predicate @person.appearances.new(descriptor: "Zero", jersey_number: 0), :valid?
  end

  test "the cast card's Generate a new look keeps the typed number" do
    video = LetteredVideo.seed!
    performer = video.video_performers.find_by!(ordinal: 1)
    maker = MusicVideos::CreateRecastLook.new(performer, person_slug: @person.slug, descriptor: "Away Blue", jersey_number: "23")

    assert_equal 23, maker.call.jersey_number
  end
end
