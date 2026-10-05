# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_cast.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [component] One performer card on the cast panel: its still on a signed URL,
# its sightings as YouTube timecode links, the typeahead while it is open, and
# the recast picker: open, recast, kept, and after the cast is confirmed.
class MusicVideoPerformerViewTest < ActionView::TestCase
  setup do
    @video = NightCallCast.seed!
    @performer = @video.video_performers.find_by!(ordinal: 2)
    @key = @performer.still_object_keys.first
  end

  def render_card(performer = @performer, urls: { @key => "https://signed.example/p2.jpg?X-Amz-Signature=abc" }, recast_looks: {})
    render partial: "music_videos/performer", locals: { performer:, video: performer.music_video, still_urls: urls, recast_looks: }
  end

  def recast_path = "/music_videos/steve-aoki-night-call/performers/2/recast"

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

  # A synthetic artist: only the operator maps an on-screen person to a real one.
  test "a labelled performer shows its artist and a Change control, not the typeahead" do
    @performer.update!(artist_slug: Artist.create!(slug: "test-artist-a", name: "Test Artist A", kind: "person").slug)
    render_card

    assert_select "[data-test='performer-card'][data-resolved='true']"
    assert_select "[data-test='performer-artist']", /Test Artist A/
    assert_select "[data-test='performer-typeahead']", 0
    assert_select "input[name='clear'][value='1']"
  end

  test "once the cast is confirmed the label is read-only and the recast is still open to change" do
    @video.video_performers.each { |p| p.update!(extra: true) }
    @video.confirm_cast!
    render_card(@performer.reload)

    assert_select "[data-test='performer-extra']"
    assert_select "[data-test='performer-resolution'] form", 0
    assert_select "[data-test='performer-recast'][data-state='open'] form[action=?]", recast_path, 2
  end

  test "an open card renders the recast picker: athlete typeahead, look step, new-look link and keep as is" do
    render_card

    assert_select "[data-test='performer-recast'][data-state='open']" do
      assert_select "[data-test='recast-typeahead'][x-data='recastTypeahead()'][data-search-url='/recast_athletes/search.json']" do
        assert_select "form[action=?] input[name='_method'][value='patch']", recast_path
        assert_select "input[type='hidden'][name='person_slug']"
        assert_select "input[type='hidden'][name='appearance_slug']"
        assert_select "input[role='combobox'][placeholder='Search people by name']"
        assert_select "[data-test='recast-no-match']", /No person matches that name/
        assert_select "[data-test='recast-looks'][x-show='athlete && athlete.looks.length'] [data-test='recast-look-option']"
        assert_select "a[data-test='recast-new-look']"
      end
      assert_select "[data-test='recast-typeahead'][data-new-look-url=?]",
                    "/people/__slug__?return_to=%2Fmusic_videos%2Fsteve-aoki-night-call%23person-2#new-model"
      assert_select "form[action=?] input[name='keep'][value='1']", recast_path
      assert_select "button", "Keep as is"
    end
    assert_includes rendered, %(x-text="athlete.name + ' > ' + look.descriptor")
  end

  # The row is an Alpine template: the browser fills it (e2e/music_video_search_rows.spec.js).
  # Here: both typeaheads render the one partial, and it binds what the endpoints send.
  test "both typeaheads render the shared search row: headshot or placeholder, name, vocation and team" do
    render_card

    { "typeahead-results" => "typeahead-option", "recast-results" => "recast-option" }.each do |list, option|
      assert_select "[data-test='#{list}'] button[role='option'][data-test='#{option}']", 1 do
        assert_select "[data-test='search-row-avatar']" do
          assert_select "template[x-if='r.avatar_url && !r.avatarFailed']"
          assert_select "svg[data-test='search-row-placeholder'][x-show='!r.avatar_url || r.avatarFailed']"
        end
        assert_select "[data-test='search-row-name'][x-text='r.name']"
        assert_select "[data-test='search-row-utility'] [data-test='search-row-vocation'][x-text=?]", "r.vocation || 'person'"
        assert_select "[data-test='search-row-utility'] [x-show='r.team'] [data-test='search-row-team'][x-text='r.team']"
        assert_select "[data-test='search-row-badge']"
      end
    end
    assert_includes rendered, %(<img :src="r.avatar_url" alt="" loading="lazy" class="block w-full h-full object-cover" @error="r.avatarFailed = true")
    assert_select "[data-test='recast-results'] [data-test='search-row-badge'][x-text='r.hint']", 1, "the looks count, 0 looks included"
    assert_select "[data-test='typeahead-results'] [data-test='search-row-badge'][x-text=?]", "r.type === 'person' ? 'people' : r.kind"
  end

  test "a look-less athlete's card offers to create a look instead of a look select" do
    lookless = Person.create!(first_name: "Test", last_name: "Athlete Gamma", athlete: true)
    @performer.update!(recast_person_slug: lookless.slug)
    render_card

    assert_select "[data-test='performer-recast'][data-state='pending']" do
      assert_select "[data-test='recast-label']", "Test Athlete Gamma"
      assert_select "[data-test='recast-no-look']", /Test Athlete Gamma has no look yet/
      assert_select "[data-test='recast-pending']", 0
      assert_select "[data-test='recast-look-form']", 0
      assert_select "a[data-test='recast-new-look'][href=?]",
                    "/people/test-athlete-gamma?return_to=%2Fmusic_videos%2Fsteve-aoki-night-call%23person-2#new-model",
                    "Create a look for Test Athlete Gamma"
      assert_select "[data-test='recast-clear'] input[name='clear'][value='1']"
    end
  end

  # A synthetic athlete: only the operator says who replaces an on-screen person.
  test "a recast card shows athlete then look, the athlete's other looks, a new-look link and Change" do
    athlete = RecastVideo.athlete!
    home, away = athlete.appearances.order(:created_at, :id).to_a
    @performer.update!(recast_person_slug: athlete.slug, recast_appearance_slug: away.slug)
    render_card(recast_looks: { athlete.slug => [home, away] })

    assert_select "[data-test='performer-card'][data-resolved='false']", 1, "a music video card still needs its artist"
    assert_select "[data-test='performer-recast'][data-state='recast']" do
      assert_select "[data-test='recast-label']", "Test Athlete Alpha > Away White"
      assert_select "[data-test='recast-typeahead']", 0
      assert_select "[data-test='recast-look-form'][action=?]", recast_path do
        assert_select "input[name='person_slug'][value=?]", athlete.slug
        assert_select "option", 2
        assert_select "option[selected][value=?]", away.slug, "Test Athlete Alpha > Away White"
      end
      assert_select "a[data-test='recast-new-look'][href=?]",
                    "/people/test-athlete-alpha?return_to=%2Fmusic_videos%2Fsteve-aoki-night-call%23person-2#new-model",
                    "New look for Test Athlete Alpha"
      assert_select "[data-test='recast-clear'] input[name='clear'][value='1']"
    end
  end

  test "an athlete whose look is gone asks for another" do
    athlete = RecastVideo.athlete!
    @performer.update!(recast_person_slug: athlete.slug)
    render_card(recast_looks: { athlete.slug => athlete.appearances.to_a })

    assert_select "[data-test='performer-recast'][data-state='pending']" do
      assert_select "[data-test='recast-label']", "Test Athlete Alpha"
      assert_select "[data-test='recast-pending']", /No look chosen/
      assert_select "[data-test='recast-look-form'] option", 3
      assert_select "[data-test='recast-look-form'] option[value='']", "Choose a look"
    end
  end

  test "a kept card says so and offers Change, not the picker" do
    @performer.update!(recast_keep: true)
    render_card

    assert_select "[data-test='performer-recast'][data-state='keep']" do
      assert_select "[data-test='recast-keep']", /Kept as is/
      assert_select "[data-test='recast-typeahead']", 0
      assert_select "[data-test='recast-clear'][action=?] input[name='clear'][value='1']", recast_path
    end
  end

  test "a cinematic card closes on its recast answer and keeps the artist optional" do
    video = RecastVideo.video!
    video.update_columns(stage: "digested")
    kept = video.video_performers.first
    render_card(kept, urls: {})

    assert_select "[data-test='performer-card'][data-resolved='true'] [data-test='performer-closed-by-recast']", "Kept"
    assert_select "[data-test='performer-typeahead']", 1
    assert_select "[data-test='performer-artist-optional']", /naming one is optional/
  end
end
