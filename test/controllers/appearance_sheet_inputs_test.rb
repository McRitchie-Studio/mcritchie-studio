require "test_helper"

# [integration] THE OPERATOR ATTACHES AN ARCHETYPE AND UNIFORM PHOTOS TO A LOOK.
# The search is stubbed; nothing here reaches a provider. Synthetic people only.
class AppearanceSheetInputsTest < ActionDispatch::IntegrationTest
  setup do
    Appearance.delete_all
    @admin = users(:alex)
    @viewer = users(:viewer)
    @person = Person.create!(first_name: "Quill", last_name: "Arcwright")
    Athlete.create!(person_slug: @person.slug, sport: "football", position: "WR")
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Comets home")
  end

  def look_path = person_appearance_path(@person.slug, @look.slug)

  def found
    results = 4.times.map do |i|
      Appearances::ImageSearch::Result.new(image_url: "https://img.example.test/#{i}.jpg", title: "Game #{i}",
                                           position: i)
    end
    Appearances::ImageSearch::Answer.new(results: results, unparsed_count: 0, provider_name: "stub")
  end

  test "a non-admin cannot buy the uniform search" do
    log_in_as(@viewer)
    Appearances::ImageSearch.stub(:search, ->(**) { flunk "the search must not run" }) do
      post search_uniform_person_appearance_path(@person.slug, @look.slug)
    end
    assert_equal 0, AppearanceUniformPhoto.count
  end

  # Choosing copies the photo (Appearances::MirrorUniformPhoto); stubbed here to the
  # address the copy would get, so nothing is fetched or uploaded.
  def copying(&block)
    copy = ->(photo, **) { photo.update!(hosted_url: "https://assets.example.test/uniform-photos/#{photo.slug}.jpg") }
    Appearances::MirrorUniformPhoto.stub(:call, copy, &block)
  end

  test "search, choose three, refuse a fourth, drop one, and point the look at an archetype" do
    log_in_as(@admin)

    Appearances::ImageSearch.stub(:search, ->(**) { found }) do
      post search_uniform_person_appearance_path(@person.slug, @look.slug)
    end
    assert_redirected_to look_path
    assert_equal 4, @look.uniform_photos.count

    photos = @look.uniform_photos.order(:position).to_a
    copying do
      photos.first(3).each do |photo|
        post pick_uniform_person_appearance_path(@person.slug, @look.slug), params: { photo_slug: photo.slug, chosen: true }
      end
      post pick_uniform_person_appearance_path(@person.slug, @look.slug), params: { photo_slug: photos.last.slug, chosen: true }
    end
    assert_match(/at most 3/, flash[:alert])
    assert_equal 3, @look.uniform_photos.chosen.count
    assert @look.uniform_photos.chosen.all?(&:hosted?), "every chosen photo has our copy"
    assert_nil photos.last.reload.hosted_url, "a refused fourth is not copied either"

    post pick_uniform_person_appearance_path(@person.slug, @look.slug), params: { photo_slug: photos.first.slug, chosen: false }
    assert_equal 2, @look.uniform_photos.chosen.count

    patch archetype_person_appearance_path(@person.slug, @look.slug), params: { body_archetype_slug: "nfl-lineman" }

    get look_path
    assert_response :success
    assert_select "[data-test=uniform-chosen] [data-test=uniform-photo]", 2
    assert_select "[data-test=uniform-chosen] [data-test=uniform-photo-open][href^='https://assets.example.test/']", 2
    assert_select "[data-test=uniform-candidates] [data-test=uniform-photo]", 2
    assert_select "[data-test=archetype-current][data-slug='nfl-lineman']"
  end

  test "a fresh look shows its position default and no uniform photos" do
    log_in_as(@admin)
    get look_path

    assert_select "[data-test=archetype-current][data-slug='nfl-receiver-db']"
    assert_select "[data-test=uniform-none]"
  end

  # THE BLOCK'S POINT (4): a photo we cannot copy is refused at the pick, free, with
  # the reason, before any build could be claimed with it.
  test "a photo whose copy fails is not chosen, and the operator reads why" do
    log_in_as(@admin)
    photo = @look.uniform_photos.create!(image_url: "https://img.example.test/hotlinked.jpg")
    refuse = ->(*, **) { raise Appearances::MirrorUniformPhoto::Refused, "its host would not hand it over (HTTP 403)" }

    Appearances::MirrorUniformPhoto.stub(:call, refuse) do
      assert_no_difference -> { ErrorLog.count } do
        post pick_uniform_person_appearance_path(@person.slug, @look.slug), params: { photo_slug: photo.slug, chosen: true }
      end
    end

    assert_redirected_to look_path
    assert_match(/Not chosen: we could not copy it: its host would not hand it over \(HTTP 403\)/, flash[:alert])
    assert_not photo.reload.chosen?
  end

  test "a full set says to remove one rather than silently hiding Use" do
    log_in_as(@admin)
    4.times do |i|
      @look.uniform_photos.create!(image_url: "https://img.example.test/#{i}.jpg", position: i, chosen: i < 3,
                                   chosen_at: i < 3 ? Time.current + i : nil,
                                   hosted_url: i < 3 ? "https://assets.example.test/#{i}.jpg" : nil)
    end

    get look_path
    assert_select "[data-test=uniform-full]", /Remove one to use another/
    assert_select "[data-test=uniform-use]", 0
    assert_select "[data-test=uniform-candidates] [data-test=uniform-photo-open][href='https://img.example.test/3.jpg']"
  end

  test "the search button names its cost from the provider that would serve it" do
    log_in_as(@admin)

    get look_path
    assert_select "[data-test=uniform-search] button", "Find game photos (free search)"

    Appearances::ImageSearch.stub(:provider_name, "serper") do
      assert_equal "Find game photos (1 paid search)", Appearances::GatherUniformPhotos.button_label
    end
  end

  test "an imageless archetype links the operator to the page that generates one" do
    log_in_as(@admin)
    get look_path

    assert_select "[data-test=archetype-no-image-link][href='/body-archetypes']"
    assert_select "[data-test=archetype-generate-link][href='/body-archetypes']"
  end
end
