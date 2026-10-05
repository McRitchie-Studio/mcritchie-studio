# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_cast.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [component] One performer card on the cast panel: its still on a signed URL,
# its sightings as YouTube timecode links, the typeahead while it is open, and
# the recast picker (the look dropdown, its preview and the generate form):
# open, recast, kept, and after the cast is confirmed.
class MusicVideoPerformerViewTest < ActionView::TestCase
  setup do
    @video = NightCallCast.seed!
    @performer = @video.video_performers.find_by!(ordinal: 2)
    @key = @performer.still_object_keys.first
  end

  def render_card(performer = @performer, urls: { @key => "https://signed.example/p2.jpg?X-Amz-Signature=abc" }, recast_looks: nil, **locals)
    recast_looks ||= MusicVideos::LookOptions.for([performer.recast_person_slug])
    render partial: "music_videos/performer", locals: { performer:, video: performer.music_video, still_urls: urls, recast_looks:, **locals }
  end

  # The rows the saved card hands its look picker.
  def picker_data = JSON.parse(css_select("[data-test='recast-looks']").first["data-athlete"])

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

  test "an open card renders the recast picker: athlete typeahead, the look picker and keep as is" do
    render_card

    assert_select "[data-test='performer-recast'][data-state='open']" do
      assert_select "[data-test='recast-typeahead'][x-data='recastTypeahead()'][data-search-url='/recast_athletes/search.json']" do
        assert_select "input[role='combobox'][placeholder='Search people by name']"
        assert_select "[data-test='recast-no-match']", /No person matches that name/
        assert_select "[data-test='look-picker'][x-show='athlete']", 1
        assert_select "form[data-test='recast-look-form'][action=?] input[name='_method'][value='patch']", recast_path
      end
      assert_select "[data-test='recast-typeahead'][data-looks-url='/recast_athletes/__slug__/looks.json']"
      assert_select "[data-test='recast-typeahead'][data-new-look-url=?]",
                    "/people/__slug__?return_to=%2Fmusic_videos%2Fsteve-aoki-night-call%23person-2#new-model"
      assert_select "[data-test='recast-typeahead'][data-athlete]", 0, "nobody is chosen until the typeahead says so"
      assert_select "form[action=?] input[name='keep'][value='1']", recast_path
      assert_select "button", "Keep as is"
    end
  end

  # The picker is an Alpine template the browser fills (e2e/music_video_look_picker.spec.js).
  # Here: its parts are on the page once per card, bound to what LookOptions sends.
  test "the look picker is a listbox of looks with thumbnails, a preview, the cast button and the generate row" do
    render_card

    assert_select "[data-test='look-picker']", 1 do
      assert_select "button[data-test='look-trigger'][role='combobox'][aria-haspopup='listbox'][aria-controls='look-list-2']" do
        assert_select "[data-test='look-thumb'] template[x-if='chosen && chosen.image_url && !chosen.imageFailed']"
        assert_select "#look-current-2[x-text=?]", "chosen ? chosen.descriptor : 'Choose a look'"
      end
      assert_select "#look-list-2[role='listbox'][x-show='listOpen']" do
        assert_select "template[x-for='(look, i) in looks'] > [role='option'][data-test='look-option']", 1
        assert_select "[data-test='look-option']" do
          assert_select "[data-test='look-thumb'] template[x-if='look && look.image_url && !look.imageFailed'] > img[alt='']", 1
          assert_select "svg[data-test='look-thumb-placeholder'][x-show='!look || !look.image_url || look.imageFailed']"
          assert_select "[data-test='look-option-name'][x-text='look.descriptor']"
          assert_select "[data-test='look-option-state'][x-text='stateLabel(look)']"
          assert_select "[data-test='look-option-default'][x-show='look.default']", "default"
        end
        assert_select "> [role='option'][data-test='look-generate-option']", /Generate a new look/
      end
      assert_select "figure[data-test='look-preview'][x-show='chosen']" do
        assert_select "template[x-if='chosen && chosen.image_url && !chosen.imageFailed'] > a[target='_blank'] > img[data-test='look-preview-image']", 1
        assert_select "[data-test='look-preview-empty'] [x-text=?]", "chosen ? emptyPreview(chosen) : ''"
        assert_select "a[data-test='look-page-link']", "Open look"
      end
      assert_select "form[data-test='recast-look-form'][x-show='chosen && lookSlug !== savedLook'][action=?]", recast_path do
        assert_select "input[type='hidden'][name='person_slug']"
        assert_select "input[type='hidden'][name='appearance_slug']"
        assert_select "button[type='submit'][data-test='look-cast']", /Cast as/
        assert_select "[data-test='look-cast-no-sheet']", /It can be cast now/
      end
      assert_select "button[data-test='look-generate-first'][x-show='looks.length === 0 && !genOpen']", "Generate first look"
      assert_select "[data-test='look-building-note'][role='status'][x-show='buildingElsewhere']"
      assert_select "a[data-test='recast-new-look']", /Or add a look by hand/
    end
  end

  test "the generate form posts the athlete and a look name to the card's own action" do
    render_card

    assert_select "form[data-test='look-generate-form'][x-show='genOpen'][method='post'][action=?]",
                  "/music_videos/steve-aoki-night-call/performers/2/recast_looks" do
      assert_select "input[type='hidden'][name='person_slug']"
      assert_select "input[name='descriptor'][required][placeholder='Broncos blue']"
      assert_select "label[for='look-name-2']", "Look name: the uniform or colours"
      assert_select "input[name='number']"
      assert_select "input[name='reference_url']"
      assert_select "button[type='submit'][data-test='look-generate-submit']", /Generate look/
      assert_select "input[name='_method']", 0
    end
  end

  test "the generate form says what a press costs, or that nothing is spent here" do
    row = ImageGeneration::Registry.preferred(:character_sheet)

    render_card(sheet_row: row, sheet_ready: true)
    assert_select "[data-test='look-cost-hint']", /Costs money: makes the look and builds one character sheet on GPT-5 image generation \(Responses\), about 6,724–7,629 tokens per sheet/

    render_card(sheet_row: row, sheet_ready: false)
    assert_select "[data-test='look-cost-hint']", /is not configured here, so the look is made without a character sheet and nothing is spent/

    render_card
    assert_select "[data-test='look-cost-hint']", /No image generator can build a character sheet here/
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
  end

  test "a Replaced by row shows the person's default look beside the count; the artist search draws no look line" do
    render_card

    assert_select "[data-test='recast-results'] button[data-test='recast-option']" do
      assert_select "[data-test='search-row-look'][x-show='r.default_look']", 1 do
        assert_select "[data-test='look-thumb'] template[x-if='r.default_look && r.default_look.image_url && !r.default_look.imageFailed'] > img", 1
        assert_select "svg[data-test='look-thumb-placeholder']", 1
        assert_select "[data-test='search-row-look-name'][x-text=?]", "r.default_look ? r.default_look.descriptor : ''"
        assert_select "span", text: "Primary look"
      end
      assert_select "[data-test='search-row-avatar'] [data-test='look-thumb']", 0, "the look is not the person's picture"
      assert_select "[data-test='search-row-avatar'] ~ * [data-test='search-row-look']", 0
      assert_select "[data-test='search-row-badge'][x-text='r.hint']", 1
    end
    assert_select "[data-test='typeahead-results'] [data-test='search-row-look']", 0
    assert_select "[data-test='typeahead-results'] [data-test='search-row-badge'][x-text=?]", "r.type === 'person' ? 'people' : r.kind"
  end

  test "a look-less athlete's card hands the picker no looks, so it offers the first one" do
    lookless = Person.create!(first_name: "Test", last_name: "Athlete Gamma", athlete: true)
    @performer.update!(recast_person_slug: lookless.slug)
    render_card

    assert_select "[data-test='performer-recast'][data-state='pending']" do
      assert_select "[data-test='recast-label']", "Test Athlete Gamma"
      assert_select "[data-test='recast-pending']", 0
      assert_select "[data-test='recast-typeahead']", 0
      assert_equal({ "slug" => "test-athlete-gamma", "name" => "Test Athlete Gamma", "looks" => [] }, picker_data)
      assert_select "[data-test='recast-no-look'][x-show='looks.length === 0']", /has no look yet/
      assert_select "[data-test='recast-clear'] input[name='clear'][value='1']"
    end
  end

  # A synthetic athlete: only the operator says who replaces an on-screen person.
  test "a recast card shows athlete then look, hands the picker every look and the saved one, and offers Change" do
    athlete = RecastVideo.athlete!
    home, away = athlete.appearances.order(:created_at, :id).to_a
    @performer.update!(recast_person_slug: athlete.slug, recast_appearance_slug: away.slug)
    render_card(fresh_look: home.slug)

    assert_select "[data-test='performer-card'][data-resolved='false']", 1, "a music video card still needs its artist"
    assert_select "[data-test='performer-recast'][data-state='recast']" do
      assert_select "[data-test='recast-label']", "Test Athlete Alpha > Away White"
      assert_select "[data-test='recast-typeahead']", 0
      assert_select "[data-test='recast-looks'][x-data='lookPicker()'][data-saved-look=?][data-fresh-look=?]", away.slug, home.slug
      assert_select "[data-test='recast-looks'][data-looks-url='/recast_athletes/__slug__/looks.json']"
      assert_equal ["test-athlete-alpha", "Test Athlete Alpha"], picker_data.values_at("slug", "name")
      assert_equal [[home.slug, "Home Blue", true, nil, "empty", "/people/test-athlete-alpha/models/#{home.slug}"],
                    [away.slug, "Away White", false, nil, "empty", "/people/test-athlete-alpha/models/#{away.slug}"]],
                   picker_data["looks"].map { |look| look.values_at("slug", "descriptor", "default", "image_url", "state", "url") }
      assert_select "[data-test='recast-clear'] input[name='clear'][value='1']"
    end
  end

  test "a look's character sheet reaches the picker as its image" do
    athlete = RecastVideo.athlete!
    home = athlete.appearances.order(:created_at, :id).first
    sheet = Artifact.create!(kind: "character_sheet", image_url: "https://example.test/home-blue.png", source: "test")
    sheet.subjects.create!(person_slug: athlete.slug, appearance_slug: home.slug, ordinal: 1)
    @performer.update!(recast_person_slug: athlete.slug, recast_appearance_slug: home.slug)
    render_card

    assert_equal [["https://example.test/home-blue.png", "ready"], [nil, "empty"]],
                 picker_data["looks"].map { |look| look.values_at("image_url", "state") }
  end

  test "an athlete whose look is gone asks for another" do
    athlete = RecastVideo.athlete!
    @performer.update!(recast_person_slug: athlete.slug)
    render_card

    assert_select "[data-test='performer-recast'][data-state='pending']" do
      assert_select "[data-test='recast-label']", "Test Athlete Alpha"
      assert_select "[data-test='recast-pending']", /No look chosen/
      assert_select "[data-test='recast-looks'][data-saved-look='']"
      assert_equal 2, picker_data["looks"].size
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
