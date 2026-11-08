require "test_helper"

# [component] The hub's NFL and people pages on the engine page header (task
# hub-remaining-page-headers). Each hand-rolled header (back link plus hero, centred
# hero, or a title in a card) is now studio/page_header: the old back link ends the
# trail, the title is the page's one h1, and no header passes actions_html. Pattern:
# test/integration/task_pages_header_test.rb.
class SportsPagesHeaderTest < ActionDispatch::IntegrationTest
  ROW = ".page-header".freeze
  KINDS = %w[page-header-menu page-header-action page-header-tools].freeze

  setup do
    @person = people(:josh_allen)
    @look = Appearance.create!(person_slug: @person.slug, descriptor: "Header look")
    @person.update!(default_appearance_slug: @look.slug)
  end

  # Gets the page with the engine's deprecation hook armed: no header on it may pass
  # actions_html, and every control on the right must be one of the engine's kinds.
  def get_header(path)
    sites = []
    Studio::PageHeader.stub(:warning_enabled?, true) do
      Studio::PageHeader.stub(:deprecate_actions_html, ->(site: nil, **) { sites << site }) do
        get path
      end
    end
    assert_response :success
    assert_empty sites, "#{path} passes actions_html to studio/page_header"
    css_select("#{ROW} .page-header-actions > *").each do |el|
      assert_includes KINDS, el["class"].to_s.split.first, "#{path}: a header control outside the four kinds"
    end
  end

  def crumb_hrefs = css_select("#{ROW} nav.page-header-crumbs a.page-header-crumb").map { |a| a["href"] }

  # Each public page: its address, its title, and the crumbs its trail must carry, the
  # old back link's target last. The rankings and contracts named the NFL Hub.
  def public_pages
    hub = [ nfl_hub_path ]
    [
      { path: nfl_quarterback_rankings_path, title: "🏈 Quarterback Rankings", crumbs: hub },
      { path: nfl_offensive_line_rankings_path, title: "🛡️ Offensive Line Rankings", crumbs: hub },
      { path: nfl_receiving_rankings_path, title: "🧤 Receiving Rankings", crumbs: hub },
      { path: nfl_rushing_rankings_path, title: "🏃 Rushing Rankings", crumbs: hub },
      { path: nfl_defense_rankings_path, title: "🛡️ Defense Rankings", crumbs: hub },
      { path: nfl_pass_rush_rankings_path, title: "💥 Pass Rush Rankings", crumbs: hub },
      { path: nfl_coverage_rankings_path, title: "🔒 Coverage Rankings", crumbs: hub },
      { path: nfl_prospects_path, title: "🎓 2025 NFL Draft Prospects", crumbs: hub },
      { path: nfl_coaches_path, title: "🎙️ NFL Coaches", crumbs: hub },
      { path: nfl_pass_first_rankings_path, title: "✈️ Pass-First Rankings", crumbs: hub },
      { path: nfl_contracts_path, title: "📋 NFL Contracts", crumbs: hub },
      { path: nfl_team_rankings_path("buffalo-bills"), title: /Buffalo Bills/, crumbs: hub },
      { path: nfl_player_impact_path(player_id: "david-bailey", team_id: "buffalo-bills"),
        title: "What if David Bailey joined the Buffalo Bills?",
        crumbs: [ nfl_hub_path, nfl_team_rankings_path("buffalo-bills") ] },
      { path: nfl_rosters_path, title: "NFL Rosters", crumbs: hub },
      { path: games_season_path(2025), title: "NFL 2025 Season", crumbs: hub },
      { path: games_week_path(2025, 1), title: "NFL Week 1", crumbs: [ nfl_hub_path, games_season_path(2025) ] },
      { path: game_show_path(2025, 1, "buf-at-mia"), title: "Buffalo Bills @ Miami Dolphins",
        crumbs: [ nfl_hub_path, games_season_path(2025), games_week_path(2025, 1) ] },
      { path: nfl_team_grades_path(team_slug: "buffalo-bills"), title: "Buffalo Bills Pass & Run Grades", crumbs: hub }
    ]
  end

  # The admin pages: a person, the rename, and photo scouting, under People (itself under
  # the Admin dashboard and the Basement).
  def admin_pages
    person = person_path(@person.slug)
    people = [ admin_dashboard_path, admin_basement_path, people_path ]
    [
      { path: person, title: @person.full_name, crumbs: people },
      { path: edit_slug_person_path(@person.slug), title: "Rename #{@person.full_name}", crumbs: people + [ person ] },
      { path: person_scouting_path(@person.slug), title: @person.full_name, crumbs: people + [ person ] }
    ]
  end

  def assert_page_header(page)
    get_header page[:path]

    assert_select ROW, { count: 1 }, "#{page[:path]}: one page header"
    assert_select "h1", { count: 1 }, "#{page[:path]}: one h1 on the page"
    assert_select "#{ROW} h1.page-header-title", { count: 1 }, "#{page[:path]}: the h1 is the header's title"
    assert_select "#{ROW} h1.page-header-title", { text: page[:title] }, "#{page[:path]}: the title"
    assert_select "#{ROW} nav.page-header-crumbs[aria-label=Breadcrumb]", { count: 1 }, "#{page[:path]}: a crumb trail"
    assert_select "#{ROW} a.page-header-parent", { count: 1 }, "#{page[:path]}: the phone's parent link"
    assert_equal page[:crumbs], crumb_hrefs, "#{page[:path]}: the trail, root first, ends at the old back link"
  end

  test "[component] each NFL page renders studio/page_header with its trail and exactly one h1" do
    public_pages.each { |page| assert_page_header(page) }
  end

  test "[component] each person page renders studio/page_header under People with exactly one h1" do
    log_in_as(users(:alex))
    admin_pages.each { |page| assert_page_header(page) }
  end

  test "[component] the NFL Hub is the trail's root: a header and its one h1, no trail" do
    get_header nfl_hub_path

    assert_select "#{ROW} h1.page-header-title", text: "NFL Hub"
    assert_select "h1", count: 1
    assert_select "#{ROW} nav.page-header-crumbs", count: 0
  end

  test "[component] the gradient heroes are gone: no white h1, no NFL Hub back link outside the trail" do
    public_pages.each do |page|
      get page[:path]
      assert_select "h1.text-white", { count: 0 }, "#{page[:path]}: the hero's h1"
      assert_select "a[href=?]:not(.page-header-crumb):not(.page-header-parent)", nfl_hub_path,
                    { text: /\ANFL Hub\z/, count: 0 }, "#{page[:path]}: the old back link"
    end
  end

  test "[component] the season picker is the header's tabs, with the shown season current" do
    Season.create!(league: "nfl", sport: "football", year: 2024, name: "2024 NFL Season", slug: "header-test-2024-nfl")
    get_header games_season_path(2025)

    assert_select "#{ROW} nav[aria-label=Season] a[href=?]", games_season_path(2024), text: "2024"
    assert_select "#{ROW} nav[aria-label=Season] a[href=?][aria-current=page]", games_season_path(2025), text: "2025"
    assert_select "select[onchange*='/games/']", count: 0
  end

  test "[component] player impact: the team picker moved under the header, the team colour is the meta" do
    get_header nfl_player_impact_path(player_id: "david-bailey", team_id: "buffalo-bills")

    assert_select "#{ROW} [data-test=player-impact-team]", count: 0
    assert_select "[data-test=player-impact-team] option[selected][value=buffalo-bills]"
    assert_select "#{ROW} .page-header-meta span.rounded-full"
    assert_select "#{ROW} .page-header-crumb-current", text: "Player impact"
  end

  test "[component] a person: Rename is the admin's one action, and the slug stays in the card" do
    log_in_as(users(:alex))
    get_header person_path(@person.slug)

    assert_select "#{ROW} a.page-header-action[data-test=person-rename-slug][href=?]", edit_slug_person_path(@person.slug),
                  text: "Rename"
    assert_select "[data-test=person-slug]", text: @person.slug
  end

  test "[component] photo scouting: the look is in the Links menu and the trail ends at Photo scouting" do
    log_in_as(users(:alex))
    get_header person_scouting_path(@person.slug)

    assert_select "#{ROW} .page-header-menu-list a[data-test=scouting-look-link][href=?]",
                  person_appearance_path(@person.slug, @look.slug)
    assert_select "#{ROW} .page-header-crumb-current", text: "Photo scouting"
    assert_select "[data-test=search-queries], [data-test=search-unconfigured]"
  end

  test "[component] the brand is not an h1 on a converted page (ShellHelper#page_heading?)" do
    get nfl_quarterback_rankings_path

    assert_select "nav h1", count: 0
    assert_select "h1", count: 1
  end
end
