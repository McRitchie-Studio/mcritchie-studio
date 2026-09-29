# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_cast.rb").to_s

# [component] One performer card on the cast panel: its still on a signed URL,
# its sightings as YouTube timecode links, and the typeahead while it is open.
class MusicVideoPerformerViewTest < ActionView::TestCase
  setup do
    @video = NightCallCast.seed!
    @performer = @video.video_performers.find_by!(ordinal: 2)
    @key = @performer.still_object_keys.first
  end

  def render_card(performer = @performer, urls: { @key => "https://signed.example/p2.jpg?X-Amz-Signature=abc" })
    render partial: "music_videos/performer", locals: { performer:, video: @video, still_urls: urls }
  end

  test "the still renders on its signed URL" do
    render_card

    assert_select "[data-test='performer-card'][data-ordinal='2'][data-resolved='false']" do
      assert_select "[data-test='performer-still'][data-key='#{@key}'] img[src='https://signed.example/p2.jpg?X-Amz-Signature=abc']"
      assert_select "[data-test='still-unreachable'][hidden]"
      assert_select "h2", "Person 2"
      assert_select "[data-test='performer-label']", "armchair"
    end
  end

  test "an unreachable still says so instead of a broken image" do
    render_card(urls: {})

    assert_select "[data-test='performer-still'] img", 0
    assert_select "[data-test='still-unreachable']:not([hidden])", /person_02_0042\.jpg/
  end

  test "sightings split into clear and partial, each a timecode link to that second" do
    render_card

    assert_select "[data-test='sightings-clear'] a[data-test='sighting']", 10
    assert_select "[data-test='sightings-partial'] a[data-test='sighting']", 4
    assert_select "a[data-test='sighting'][target='_blank'][href=?]", "https://www.youtube.com/watch?v=Sa7GSJJ_lOo&t=42s", "0:42"
    assert_select "[data-test='sightings-partial'] a", text: "3:27"
  end

  test "an open performer gets the typeahead, create-new and extra controls" do
    render_card

    assert_select "[data-test='performer-typeahead'][x-data='castTypeahead()'][data-search-url='/artists/search.json']" do
      assert_select "form[action='/music_videos/steve-aoki-night-call/performers/2'] input[name='_method'][value='patch']"
      assert_select "input[role='combobox'][x-model='query']"
      assert_select "input[type='hidden'][name='artist_slug']"
      assert_select "input[type='hidden'][name='person_slug']"
      assert_select "[data-test='typeahead-create']"
      assert_select "[data-test='create-artist'] input[name='new_artist_name']"
    end
    assert_select "form[action='/music_videos/steve-aoki-night-call/performers/2'] input[name='extra'][value='1']"
    assert_includes rendered, %(@input.debounce.250ms="search()")
  end

  test "a labelled performer shows its artist and a Change control, not the typeahead" do
    @performer.update!(artist_slug: Artist.find_by!(name: "Lil Yachty").slug)
    render_card

    assert_select "[data-test='performer-card'][data-resolved='true']"
    assert_select "[data-test='performer-artist']", /Lil Yachty/
    assert_select "[data-test='performer-typeahead']", 0
    assert_select "input[name='clear'][value='1']"
  end

  test "once the cast is confirmed the card is read-only" do
    @video.video_performers.each { |p| p.update!(extra: true) }
    @video.confirm_cast!
    render_card(@performer.reload)

    assert_select "[data-test='performer-extra']"
    assert_select "form", 0
  end
end
