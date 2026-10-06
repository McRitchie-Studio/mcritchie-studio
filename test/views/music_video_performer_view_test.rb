# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_cast.rb").to_s
require Rails.root.join("db/seeds/data/recast_video.rb").to_s

# [component] One performer card on the cast panel: its still on a signed URL,
# its sightings as YouTube timecode links, the optional artist typeahead, and
# Replace with (the people search on every card; a pick is the swap and shows
# the chosen athlete, the look dropdown, its preview and the generate form;
# the bottom-pinned Keep Original / Swap back button once someone is remembered): none, recast, kept, pending,
# legacy kept, the production shape, and after the cast is confirmed.
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

  # Top to bottom: heading; Replace with (inputs to swap a player in); description and sightings;
  # then pinned at the bottom the Keep Original / Swap back button and, under it, who is on screen.
  test "Replace with sits at the top of the card; the swap toggle and naming are pinned at the bottom" do
    @performer.update!(confidence_note: "Seen in the armchair throughout.")
    render_card
    at = ->(test) { rendered.index(%(data-test="#{test}")) || flunk("#{test} not rendered") }

    assert_operator at.("performer-label"), :<, at.("replace-with")
    assert_operator at.("replace-with"), :<, at.("performer-note")
    assert_operator at.("replace-with"), :<, at.("sightings-clear")
    assert_operator at.("sightings-partial"), :<, at.("card-bottom")
    assert_operator at.("card-bottom"), :<, at.("keep-toggle")
    assert_operator at.("keep-toggle"), :<, at.("performer-resolution")
    assert_operator at.("performer-resolution"), :<, at.("performer-typeahead")
    assert_select "[data-test='card-bottom'].mt-auto", 1, "pinned to the bottom, so cards in a row line up"
    assert_select "[data-test='performer-recast'].flex.flex-col.flex-1", 1, "the card body is the flex column it is pinned in"
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

  test "an unnamed performer reads Not named, with the naming search always open, create-new and extra controls" do
    render_card

    assert_select "[data-test='performer-badge'][data-state='none']", "Not named"
    assert_select "[data-test='performer-badge'][x-text]", 1, "the badge follows a naming save without a reload"
    # No link or Change to press first: a small label and the input, quieter than Replace with.
    assert_select "[data-test='performer-resolution'][x-data='namingCard()'][data-search-url='/artists/search.json'][data-ordinal='2']" do |node|
      assert_equal "/music_videos/steve-aoki-night-call/performers/2", node.first["data-save-url"]
      assert_nil node.first["data-named"]
      assert_select "label.text-xs[for='artist-search-2']", /Who is this on screen\?\s+\(optional\)/
      assert_select "[data-test='performer-typeahead']:not([x-show]):not([x-cloak]) input#artist-search-2[role='combobox'][x-model='query'][placeholder='Search artists and people'].py-1\\.5", 1
      assert_select "[data-test='typeahead-create']"
      assert_select "[data-test='create-artist'][x-cloak] button[data-test='create-artist-submit']", "Create and link"
      assert_select "button[data-test='mark-extra']:not([x-cloak])", "Mark as extra"
      assert_select "[data-test='performer-artist'][x-cloak]", 1
      assert_select "[data-test='performer-extra'][x-cloak]", 1
      assert_select "form", 0, "every naming change saves itself as JSON"
    end
    assert_select "[data-test='name-artist-open'], [data-test='performer-artist-change'], [data-test='naming-panel']", 0
    assert_select "[data-test='replace-with'] > div > label.label-upper[for='recast-search-2']", "Replace with"
    assert_includes rendered, %(@input.debounce.250ms="search()")
    assert_includes rendered, %(@click="markExtra()")
  end

  # A synthetic artist: only the operator maps an on-screen person to a real one.
  test "a named performer shows its artist with a small Clear, the search still open underneath" do
    @performer.update!(artist_slug: Artist.create!(slug: "test-artist-a", name: "Test Artist A", kind: "person").slug)
    render_card

    assert_select "[data-test='performer-card'][data-resolved='true'][data-named='true']"
    assert_select "[data-test='performer-badge'][data-state='named']", "Named"
    assert_select "[data-test='performer-resolution']" do |node|
      assert_equal({ "kind" => "artist", "slug" => "test-artist-a", "name" => "Test Artist A", "avatar_url" => nil,
                     "vocation" => "musician", "team" => nil }, JSON.parse(node.first["data-named"]))
      assert_select "[data-test='performer-artist']:not([x-cloak])" do
        assert_select "[data-test='performer-artist-name']", "Test Artist A"
        assert_select "[data-test='performer-artist-utility']", "musician"
        assert_select "button[data-test='performer-artist-clear']", "Clear"
      end
      assert_select "[data-test='performer-typeahead']:not([x-cloak]) input[role='combobox']", 1
    end
    assert_select "[data-test='swap-offer']", 1
    assert_nil css_select("[data-test='performer-recast']").first["data-offer"], "an artist with no Person and no looks offers no swap"
  end

  # A synthetic athlete: only the operator says who is on screen and who replaces them.
  test "named after an athlete with looks: the headshot, vocation and team, and a one-click Swap with offer, never automatic" do
    athlete = RecastVideo.athlete!
    team = Team.create!(slug: "test-city-testers", name: "Test City Testers")
    profile = Athlete.create!(person_slug: athlete.slug, sport: "football", team_slug: team.slug)
    cache = ImageCache.create!(owner: profile, purpose: "headshot", variant: "100", content_type: "image/png",
                               s3_key: "headshots/nfl/test-city-testers/#{athlete.slug}/100.png")
    artist = Artist.create!(slug: "test-athlete-alpha-artist", name: "Test Athlete Alpha", kind: "person", person_slug: athlete.slug)
    @performer.update!(artist_slug: artist.slug)
    render_card(recast_looks: MusicVideos::LookOptions.for([athlete.slug]), recast_rows: People::SearchRows.for([athlete.slug]))

    named = JSON.parse(css_select("[data-test='performer-resolution']").first["data-named"])
    assert_equal [cache.url, "athlete", "Test City Testers"], named.values_at("avatar_url", "vocation", "team")
    assert_select "[data-test='performer-artist-utility']", "athlete · Test City Testers"
    assert_select "[data-test='performer-recast'][data-state='none'][data-keep='false']" do |node|
      offer = JSON.parse(node.first["data-offer"])
      assert_equal ["test-athlete-alpha", "Test Athlete Alpha", "Test City Testers"], offer.values_at("slug", "name", "team")
      assert_equal ["Home Blue", "Away White"], offer["looks"].pluck("descriptor")
      assert_select "button[data-test='swap-offer'][x-show=?]", "offer && (!swapping || athlete.slug !== offer.slug)", /Swap with/
      assert_select "[data-test='recast-typeahead'] input[role='combobox']", 1, "the search is there beside the offer"
    end
    assert_nil @performer.reload.recast_person_slug, "the offer is offered, not done"
    assert_includes rendered, %(@click="offerSwap()")
    assert_includes rendered, %(@naming-saved.window="onNamed($event.detail)")
  end

  test "once the cast is confirmed the name and the swap both stay open to change" do
    @video.video_performers.each { |p| p.update!(extra: true) }
    @video.confirm_cast!
    render_card(@performer.reload)

    # An extra is a small removable chip, the search still open beside it.
    assert_select "[data-test='performer-resolution'] [data-test='performer-extra']:not([x-cloak])", /An extra, not a named artist/ do
      assert_select "button[data-test='performer-extra-remove'][aria-label='Not an extra']"
    end
    assert_select "[data-test='performer-resolution'] button[data-test='mark-extra'][x-cloak]", 1
    assert_select "[data-test='performer-resolution'] [data-test='performer-typeahead'] input[role='combobox']", 1
    assert_select "[data-test='performer-badge'][data-state='extra']", "Extra"
    assert_select "[data-test='performer-recast'][data-state='none'][data-save-url=?]", recast_path
    assert_select "[data-test='recast-typeahead']:not([x-show]) input[role='combobox']", 1
    assert_includes rendered, %(@click="keepOriginal()")
    assert_includes rendered, %(@click="swapBack()")
    assert_includes rendered, %(@click="retry()")
    assert_includes rendered, %(@click="clearPerson()")
  end

  test "a card with no pick shows only the Replace with search: no toggle, no hint, no Keep Original" do
    render_card

    assert_select "[data-test='performer-recast'][x-data='swapCard()'][data-state='none'][data-keep='false']" do |node|
      assert_equal ["", "", "/music_videos/steve-aoki-night-call/performers/2/recast"],
                   node.first.attributes.values_at("data-saved-person", "data-saved-look", "data-save-url").map(&:value)
      # Always there: not behind a toggle, not hidden while someone is chosen.
      assert_select "[data-test='recast-typeahead']:not([x-show]):not([x-cloak])" do
        assert_select "input#recast-search-2[role='combobox'][placeholder='Search people by name']"
        assert_select "[data-test='recast-no-match']", /No person matches that name/
      end
      # Nobody remembered: the bottom toggle waits hidden, neither Keep Original nor Swap back.
      assert_select "[data-test='card-bottom'] [data-test='keep-toggle'][x-show='athlete'][x-cloak]", 1
      assert_select "input[type='checkbox']", 0, "no Keep Original checkbox"
      assert_select "[data-test='keep-original-note']", 0, "no muted kept line under the search"
      assert_select "[data-test='swap-body'][x-show='swapping'][x-cloak]" do
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
    assert_select "[data-test='swap-toggle'], [role='switch']", 0, "no Swap Person toggle"
    assert_no_match(/Swap Person|Check to replace|Pick who replaces them/, rendered)
    assert_select "button", text: "Keep as is", count: 0
    assert_select "[data-test='look-cast']", 0, "every pick saves itself: no Cast button"
    assert_select "[data-test='performer-recast'] form[action=?]", recast_path, 0
  end

  test "kept: the athlete is remembered, the bottom button reads Swap back to him, and the swap block waits hidden" do
    athlete = RecastVideo.athlete!
    away = athlete.appearances.order(:created_at, :id).last
    @performer.update!(recast_person_slug: athlete.slug, recast_appearance_slug: away.slug, recast_keep: true)
    render_card

    assert_select "[data-test='performer-recast'][data-state='kept'][data-keep='true']" do |node|
      assert_equal [athlete.slug, away.slug], node.first.attributes.values_at("data-saved-person", "data-saved-look").map(&:value)
      assert_equal "Test Athlete Alpha", picker_data["name"]
      # One button, same place as Keep Original: now Swap back to <name>, with his headshot.
      assert_select "[data-test='card-bottom'] [data-test='keep-toggle']:not([x-cloak])" do
        assert_select "button[data-test='swap-back']:not([x-cloak])", /Swap back to\s+Test Athlete Alpha/ do
          assert_select "[data-test='search-row-avatar']", 1
          assert_select "[data-test='swap-back-name']", "Test Athlete Alpha"
        end
        assert_select "button[data-test='keep-original'][x-cloak]", 1
      end
      assert_includes rendered, %(@click="swapBack()")
      assert_select "[data-test='swap-body'][x-cloak]"
      assert_select "[data-test='recast-typeahead']:not([x-cloak]) input[role='combobox']", 1, "a new pick is the other way out"
    end
    assert_select "[data-test='performer-card'][data-resolved='true']"
  end

  test "the legacy kept card with nobody remembered reads as no pick: the search alone" do
    @performer.update!(recast_keep: true)
    render_card

    assert_select "[data-test='performer-recast'][data-state='none'][data-keep='false'][data-saved-person='']" do
      assert_select "[data-test='keep-toggle'][x-cloak]"
      assert_select "[data-test='swap-body'][x-cloak]"
    end
    assert_select "[data-test='performer-card'][data-resolved='true']"
  end

  # The production row piece 10 shipped onto and this card must read the same (bigxthaplug-6wa,
  # 2026-10-05), rebuilt with synthetic people: Person 1 swapped to an athlete in a look,
  # Persons 2-5 saved under the old keep as is with nobody, the cast confirmed.
  test "the production shape: Person 1 shows the athlete with Keep Original unchecked, the rest only the search" do
    athlete = RecastVideo.athlete!
    home = athlete.appearances.order(:created_at, :id).first
    video = RecastVideo.video!
    first = video.video_performers.find_by!(ordinal: 1)
    first.update!(recast_person_slug: athlete.slug, recast_appearance_slug: home.slug, recast_keep: false)
    others = (3..5).map { |n| video.video_performers.create!(ordinal: n, label: "person #{n}", recast_keep: true) }
    others.unshift(video.video_performers.find_by!(ordinal: 2).tap { |p| p.update!(recast_keep: true) })
    looks = MusicVideos::LookOptions.for([athlete.slug])

    render_card(first, urls: {}, recast_looks: looks)
    assert_select "[data-test='performer-recast'][data-state='recast'][data-keep='false']" do
      assert_select "[data-test='swap-body']:not([x-cloak]) [data-test='swap-athlete-name']", "Test Athlete Alpha"
      assert_select "[data-test='card-bottom'] [data-test='keep-toggle']:not([x-cloak]) button[data-test='keep-original']:not([x-cloak])", "Keep Original"
      assert_select "button[data-test='swap-back'][x-cloak]", 1
      assert_equal home.slug, css_select("[data-test='performer-recast']").first["data-saved-look"]
    end

    others.each do |p|
      @rendered = +"" # one card at a time
      render_card(p.reload, urls: {}, recast_looks: looks)
      assert_select "[data-test='performer-recast'][data-state='none'][data-saved-person='']", 1, p.name
      assert_select "[data-test='keep-toggle'][x-cloak]", 1, "#{p.name} shows neither Keep Original nor Swap back"
      assert_select "[data-test='swap-body'][x-cloak]", 1
    end
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
      assert_select "[data-test='card-bottom'] [data-test='keep-toggle']:not([x-cloak]) button[data-test='keep-original']:not([x-cloak])", "Keep Original"
      assert_select "[data-test='swap-body']:not([x-cloak]) [data-test='swap-athlete-name']", "Test Athlete Gamma"
      assert_select "[data-test='recast-pending'][x-cloak]", 1, "no looks to choose from: the note waits hidden"
      assert_equal({ "slug" => "test-athlete-gamma", "name" => "Test Athlete Gamma", "avatar_url" => nil, "vocation" => "athlete",
                     "team" => nil, "looks" => [] }, picker_data)
      assert_select "[data-test='recast-no-look'][x-show='looks.length === 0']", /has no look yet/
    end
  end

  # A synthetic athlete and team: only the operator says who replaces an on-screen person.
  test "a recast card shows the chosen athlete's avatar, name and team, every look and the saved one, and Clear" do
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
      assert_select "[data-test='card-bottom'] [data-test='keep-toggle']:not([x-cloak]) button[data-test='keep-original']:not([x-cloak])", "Keep Original"
      assert_select "[data-test='swap-body'][x-show='swapping']:not([x-cloak]) [data-test='swap-athlete']" do
        assert_select "[data-test='search-row-avatar'] template[x-if='athlete && athlete.avatar_url && !athlete.avatarFailed']"
        assert_select "[data-test='swap-athlete-name']", "Test Athlete Alpha"
        assert_select "[data-test='swap-athlete-team'][x-text=?]", "athlete ? athlete.team : ''"
        assert_select "button[data-test='swap-clear']", "Clear"
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
    assert_select "[data-test='performer-resolution'] label", /\(optional\)/
  end
end
