require "test_helper"

# [unit] UNIFORM PHOTOS: one search, every result filed unchosen, the operator picks.
# The search is stubbed; nothing here reaches a provider. Synthetic people only.
class Appearances::GatherUniformPhotosTest < ActiveSupport::TestCase
  setup do
    Appearance.delete_all
    @person = Person.create!(first_name: "Quill", last_name: "Arcwright")
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Comets home", colorway: "Comets teal")
  end

  def answer(*urls)
    results = urls.each_with_index.map do |url, i|
      Appearances::ImageSearch::Result.new(image_url: url, page_url: "https://news.example.test/#{i}",
                                           title: "Game #{i}", position: i)
    end
    Appearances::ImageSearch::Answer.new(results: results, unparsed_count: 0, provider_name: "stub")
  end

  def gather(look = @look, found: answer("https://img.example.test/a.jpg", "https://img.example.test/b.jpg"))
    queries = []
    Appearances::ImageSearch.stub(:search, ->(query:, **) { queries << query; found }) do
      [Appearances::GatherUniformPhotos.call(look), queries]
    end
  end

  test "the query names the player, the colourway and game action" do
    query = Appearances::GatherUniformPhotos.new(@look).query

    assert_includes query, "Quill Arcwright"
    assert_includes query, @look.reload.colorway
    assert query.end_with?("game action")
  end

  test "one search files every result as an unchosen candidate, and a repeat files no duplicates" do
    summary, queries = gather

    assert_equal 1, queries.length, "one press is one query"
    assert_equal 2, summary.filed
    assert_equal 2, @look.uniform_photos.count
    assert @look.uniform_photos.none?(&:chosen?), "nothing is chosen until the operator chooses"

    summary, = gather
    assert_equal 0, summary.filed
    assert_equal 2, @look.uniform_photos.count
  end

  test "an iced twin files under its base: same uniform" do
    twin = Appearances::IcedTwin.create!(@look)
    gather(twin)

    assert_equal 2, @look.uniform_photos.count
    assert_equal 0, twin.uniform_photos.count
    assert_equal @look, twin.reload.uniform_source
  end

  test "at most three are chosen" do
    gather(found: answer(*4.times.map { |i| "https://img.example.test/#{i}.jpg" }))
    photos = @look.uniform_photos.order(:position).to_a

    photos.first(3).each { |p| assert p.update(chosen: true, chosen_at: Time.current) }
    assert_not photos.last.update(chosen: true), "a fourth is refused"
    assert_match(/at most 3/, photos.last.errors.full_messages.to_sentence)
  end
end
