# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_cast.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [component] One performer card on the cast panel: its still on a signed URL,
# its sightings as YouTube timecode links, the optional artist typeahead, and
# the Swap Person toggle (off by default; on, the chosen athlete or the people
# search, the look dropdown, its preview and the generate form): off, recast,
# pending, legacy kept, and after the cast is confirmed.
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

  # The athlete and rows the saved card hands its swap card.
  def picker_data = JSON.parse(css_select("[data-test='performer-recast']").first["data-athlete"])

  def recast_path = "/music_videos/steve-aoki-night-call/performers/2/recast"

  test "the still renders on its signed URL" do
    render_card

    assert_select "[data-test='performer-card'][data-ordinal='2'][data-resolved='true'][data-named='false']" do
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

  test "an unnamed performer reads Not named, with the optional typeahead, create-new and extra controls" do
    render_card

    assert_select "[data-test='performer-badge']", "Not named"
    assert_select "[data-test='performer-artist-optional']", /Optional: name the artist to add them to the rolodex/
    assert_select "button[data-test='mark-extra']", "Mark as extra"
    assert_select "button", text: "Extra, not a named artist", count: 0

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

    assert_select "[data-test='performer-card'][data-resolved='true'][data-named='true']"
    assert_select "[data-test='performer-badge']", "Named"
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
    assert_select "[data-test='performer-recast'][data-state='off'][data-save-url=?]", recast_path
    assert_select "button[data-test='swap-toggle'][role='switch']", 1
    assert_includes rendered, %(@click="toggle()")
    assert_includes rendered, %(@click="retry()")
    assert_includes rendered, %(@click="changeAthlete()")
  end

  test "a card with no swap: the toggle reads Don't Swap Person, off, and the search waits behind it" do
    render_card

    assert_select "[data-test='performer-recast'][x-data='swapCard()'][data-state='off']" do |node|
      assert_equal ["", "", "/music_videos/steve-aoki-night-call/performers/2/recast"],
                   node.first.attributes.values_at("data-saved-person", "data-saved-look", "data-save-url").map(&:value)
      assert_select "button[data-test='swap-toggle'][role='switch'][aria-checked='false']", "Don’t Swap Person"
      assert_select "[data-test='swap-off-note']", /Not swapped: this person stays as filmed/
      assert_select "[data-test='swap-body'][x-show='on'][x-cloak]" do
        assert_select "[data-test='recast-typeahead'][x-show='!athlete || searching']" do
          assert_select "input[role='combobox'][placeholder='Search people by name']"
          assert_select "[data-test='recast-no-match']", /No person matches that name/
        end
        assert_select "[data-test='look-picker'][x-show='athlete']", 1
      end
      assert_select "[data-test='swap-save-state'][role='status']" do
        assert_select "[x-show=?]", "save === 'saving'", text: "Saving…"
        assert_select "[x-show=?]", "save === 'saved'", text: "Saved"
        assert_select "[x-show=?] button[data-test='swap-retry']", "save === 'failed'", text: "Retry"
      end
    end
    assert_select "[data-test='performer-recast'][data-search-url='/recast_athletes/search.json'][data-looks-url='/recast_athletes/__slug__/looks.json']"
    assert_select "[data-test='performer-recast'][data-new-look-url=?]",
                  "/people/__slug__?return_to=%2Fmusic_videos%2Fsteve-aoki-night-call%23person-2#new-model"
    assert_select "[data-test='performer-recast'][data-athlete]", 0, "nobody is chosen until the search says so"
    assert_select "button", text: "Keep as is", count: 0
    assert_select "[data-test='look-cast']", 0, "every pick saves itself: no Cast button"
    assert_select "[data-test='performer-recast'] form[action=?]", recast_path, 0
  end

  test "a swap turned off remembers the athlete: the card is off but carries him for the toggle to restore" do
    athlete = RecastVideo.athlete!
    away = athlete.appearances.order(:created_at, :id).last
    @performer.update!(recast_person_slug: athlete.slug, recast_appearance_slug: away.slug, recast_keep: true)
    render_card

    assert_select "[data-test='performer-recast'][data-state='off'][data-swap-on='false']" do |node|
      assert_equal [athlete.slug, away.slug], node.first.attributes.values_at("data-saved-person", "data-saved-look").map(&:value)
      assert_equal "Test Athlete Alpha", picker_data["name"]
      assert_select "button[data-test='swap-toggle'][aria-checked='false']", "Don’t Swap Person"
      assert_select "[data-test='swap-body'][x-cloak]"
    end
  end

  test "on with nobody picked asks who, and says nothing is saved until then" do
    render_card

    assert_select "[data-test='swap-pick-note'][x-show='on && !athlete']", /Pick who replaces them\. Nothing is saved until you do\./
  end

  test "the legacy kept card reads the same as no swap" do
    @performer.update!(recast_keep: true)
    render_card

    assert_select "[data-test='performer-recast'][data-state='off'][data-saved-person='']" do
      assert_select "button[data-test='swap-toggle'][aria-checked='false']", "Don’t Swap Person"
    end
    assert_select "[data-test='performer-card'][data-resolved='true']"
  end

  # The picker is an Alpine template the browser fills (e2e/music_video_look_picker.spec.js).
  # Here: its parts are on the page once per card, bound to what LookOptions sends.
  test "the look picker is a listbox of looks with thumbnails, a preview and the generate row" do
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
      assert_select "form[data-test='recast-look-form']", 0
      assert_select "[data-test='look-cast-no-sheet'][x-show=?]", "chosen && chosen.state !== 'ready'", /It is cast; its chunks show the sheet/
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
          assert_select "template[x-if='r && r.avatar_url && !r.avatarFailed']"
          assert_select "svg[data-test='search-row-placeholder'][x-show='!r || !r.avatar_url || r.avatarFailed']"
        end
        assert_select "[data-test='search-row-name'][x-text='r.name']"
        assert_select "[data-test='search-row-utility'] [data-test='search-row-vocation'][x-text=?]", "r.vocation || 'person'"
        assert_select "[data-test='search-row-utility'] [x-show='r.team'] [data-test='search-row-team'][x-text='r.team']"
        assert_select "[data-test='search-row-badge']"
      end
    end
    assert_select "[data-test='recast-results'][x-ref='results']", 1, "swapCard#fitList measures the wide list"
    assert_match(/w-\[min\(40rem,calc\(100vw-2rem\)\)\]/, css_select("[data-test='recast-results']").first["class"], "wider than the card")
    assert_includes rendered, %(<img :src="r.avatar_url" alt="" loading="lazy" class="block w-full h-full object-cover" @error="r.avatarFailed = true")
    assert_select "[data-test='recast-results'] [data-test='search-row-badge'][x-text='r.hint']", 1, "the looks count, 0 looks included"
  end

  test "a Replaced by row is three columns: avatar; name, team and looks; the primary look" do
    render_card

    assert_select "[data-test='recast-results'] button[data-test='recast-option']" do |row|
      assert_match(/sm:grid-cols-\[auto_minmax\(0,1fr\)_minmax\(0,15rem\)\]/, row.first["class"])
      assert_select "> [data-test='search-row-avatar']", 1
      assert_select "> span:nth-of-type(2) [data-test='search-row-name']", 1
      assert_select "> span:nth-of-type(2) [data-test='search-row-badge'][x-text='r.hint']", 1
      assert_select "> [data-test='search-row-look-cell']", 1 do
        assert_select "[data-test='search-row-look'][x-show='r.default_look']", 1 do
          assert_select "[data-test='look-thumb'] template[x-if='r.default_look && r.default_look.image_url && !r.default_look.imageFailed'] > img", 1
          assert_select "svg[data-test='look-thumb-placeholder']", 1
          assert_select "[data-test='search-row-look-name'][x-text=?]", "r.default_look ? r.default_look.descriptor : ''"
          assert_select "span", text: "Primary look"
        end
        assert_select "[data-test='search-row-no-look'][x-show='!r.default_look']", 1
      end
      assert_select "[data-test='search-row-avatar'] [data-test='look-thumb']", 0, "the look is not the person's picture"
    end
    assert_select "[data-test='typeahead-results'] [data-test='search-row-look']", 0
    assert_select "[data-test='typeahead-results'] [data-test='search-row-badge'][x-text=?]", "r.type === 'person' ? 'people' : r.kind"
  end

  test "a look-less athlete's card is pending: the chosen athlete block and the first-look offer" do
    lookless = Person.create!(first_name: "Test", last_name: "Athlete Gamma", athlete: true)
    @performer.update!(recast_person_slug: lookless.slug)
    render_card(recast_rows: People::SearchRows.for([lookless.slug]))

    assert_select "[data-test='performer-recast'][data-state='pending']" do
      assert_select "button[data-test='swap-toggle'][aria-checked='true']", "Swap Person"
      assert_select "[data-test='swap-athlete-name']", "Test Athlete Gamma"
      assert_select "[data-test='recast-pending'][x-cloak]", 1, "no looks to choose from: the note waits hidden"
      assert_equal({ "slug" => "test-athlete-gamma", "name" => "Test Athlete Gamma", "avatar_url" => nil, "vocation" => "athlete",
                     "team" => nil, "looks" => [] }, picker_data)
      assert_select "[data-test='recast-no-look'][x-show='looks.length === 0']", /has no look yet/
    end
  end

  # A synthetic athlete and team: only the operator says who replaces an on-screen person.
  test "a recast card shows the chosen athlete's avatar, name and team, every look and the saved one, and Change" do
    athlete = RecastVideo.athlete!
    team = Team.create!(slug: "test-city-testers", name: "Test City Testers")
    Athlete.create!(person_slug: athlete.slug, sport: "football", team_slug: team.slug)
    home, away = athlete.appearances.order(:created_at, :id).to_a
    @performer.update!(recast_person_slug: athlete.slug, recast_appearance_slug: away.slug)
    render_card(fresh_look: home.slug, recast_rows: People::SearchRows.for([athlete.slug]))

    assert_select "[data-test='performer-card'][data-resolved='true']", 1
    assert_select "[data-test='performer-recast'][data-state='recast']" do |node|
      assert_equal [athlete.slug, away.slug, home.slug],
                   node.first.attributes.values_at("data-saved-person", "data-saved-look", "data-fresh-look").map(&:value)
      assert_select "button[data-test='swap-toggle'][aria-checked='true']", "Swap Person"
      assert_select "[data-test='swap-athlete'][x-show='athlete && !searching']" do
        assert_select "[data-test='search-row-avatar'] template[x-if='athlete && athlete.avatar_url && !athlete.avatarFailed']"
        assert_select "[data-test='swap-athlete-name']", "Test Athlete Alpha"
        assert_select "[data-test='swap-athlete-team'][x-text=?]", "athlete ? athlete.team : ''"
        assert_select "button[data-test='swap-change']", "Change"
      end
      assert_equal ["test-athlete-alpha", "Test Athlete Alpha", "athlete", "Test City Testers"],
                   picker_data.values_at("slug", "name", "vocation", "team")
      assert_equal [[home.slug, "Home Blue", true, nil, "empty", "/people/test-athlete-alpha/models/#{home.slug}"],
                    [away.slug, "Away White", false, nil, "empty", "/people/test-athlete-alpha/models/#{away.slug}"]],
                   picker_data["looks"].map { |look| look.values_at("slug", "descriptor", "default", "image_url", "state", "url") }
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

    assert_select "[data-test='performer-recast'][data-state='pending'][data-saved-look='']" do
      assert_select "[data-test='recast-pending'][x-show=?]", "state === 'pending' && looks.length > 0", /No look saved/
      assert_equal 2, picker_data["looks"].size
    end
    assert_select "[data-test='performer-card'][data-resolved='false']", 1, "a swap waiting for its look is owed one"
  end

  test "a cinematic card keeps the artist optional too" do
    video = RecastVideo.video!
    video.update_columns(stage: "digested")
    kept = video.video_performers.first
    render_card(kept, urls: {})

    assert_select "[data-test='performer-card'][data-resolved='true']"
    assert_select "[data-test='performer-typeahead']", 1
    assert_select "[data-test='performer-artist-optional']", /Optional/
  end
end
