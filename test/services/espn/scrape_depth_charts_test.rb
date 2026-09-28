require "test_helper"

# [unit] THE DEPTH CHART SCRAPER, AND THE TWO WAYS IT USED TO DIE QUIETLY.
#
# Both defects this suite pins were invisible from a terminal:
#
#   1. THE HOST. site.api.espn.com answers curl with 200 and Ruby with 403, so
#      hand-verifying the endpoint "proves" it works and the application still
#      cannot reach it. Re-measured 2026-09-27 from Net::HTTP: site.api answered
#      403 (437 bytes, an Akamai "Access Denied" page) to the honest UA AND to a
#      Chrome 120 string, while site.web.api answered 200 (148848 bytes) to the
#      honest UA and to no UA at all. curl got 200 and the same 148848 bytes from
#      the host Ruby cannot reach. The host is therefore pinned by an assertion,
#      not only by a comment.
#   2. THE SILENCE. An unreadable teams index produced an EMPTY abbrev=>id map,
#      every one of the 32 abbrevs then "had no ESPN team_id", and the run tallied
#      32 per-team failures — a sentence about OUR map when the truth was that
#      ESPN was unreachable. A single missing id was worse: 31 of 32 teams applied
#      and the lane stayed green, which is how a depth chart silently goes a week
#      stale.
#
# The HTTP is stubbed at #fetch_json by a subclass rather than by a mocking
# library, because this suite has none — and naming the exact URLs keeps each
# behaviour attached to the endpoint it belongs to. Espn::PlayerProfileTest draws
# the same line for the same reason.
class Espn::ScrapeDepthChartsTest < ActiveSupport::TestCase
  # A scraper whose only difference is where the bytes come from. A stubbed value
  # that is an exception is RAISED, so "ESPN was down" is expressible.
  class Stubbed < Espn::ScrapeDepthCharts
    attr_reader :requested

    def initialize(responses, **kwargs)
      super(**kwargs)
      @responses = responses
      @requested = []
    end

    private

    def fetch_json(url)
      @requested << url
      raise "unstubbed request: #{url}" unless @responses.key?(url)

      value = @responses.fetch(url)
      raise value if value.is_a?(StandardError) || (value.is_a?(Class) && value <= StandardError)

      value
    end
  end

  TEAMS_INDEX = "https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams".freeze

  # ESPN's teams index in the shape the service reads: sports[0].leagues[0].teams,
  # each row a { "team" => { "abbreviation" =>, "id" => } }. Measured 2026-09-27 —
  # the live index carried 32 rows and an id on every one.
  def teams_index(pairs)
    { "sports" => [{ "leagues" => [{ "teams" => pairs.map { |abbrev, id|
      { "team" => { "abbreviation" => abbrev.to_s.upcase, "id" => id } }
    } }] }] }
  end

  # Every abbreviation the service knows, mapped to a plausible ESPN id.
  def full_index
    teams_index(Espn::ScrapeDepthCharts::TEAM_ABBREV_TO_SLUG.keys.each_with_index.to_h { |a, i| [a, (i + 1).to_s] })
  end

  setup do
    @service = Espn::ScrapeDepthCharts.new
    @bills = teams(:buffalo_bills)
    @dolphins = teams(:miami_dolphins)
  end

  # ─── lookup_person ───────────────────────────────────────────────────────────

  test "lookup_person resolves by espn_id" do
    person = Person.create!(first_name: "Lookup", last_name: "Espn", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "777")

    found_person, found_athlete = @service.send(:lookup_person, "777", "Whatever Name")
    assert_equal person, found_person
    assert_equal athlete, found_athlete
  end

  test "lookup_person falls back to name match when espn_id misses" do
    person = Person.create!(first_name: "Fallback", last_name: "Player", athlete: true)
    Athlete.create!(person_slug: person.slug, sport: "football")

    found_person, found_athlete = @service.send(:lookup_person, nil, "Fallback Player")
    assert_equal person, found_person
    assert_equal person.athlete_profile, found_athlete
  end

  test "lookup_person returns nils when no match" do
    person, athlete = @service.send(:lookup_person, "no-such-id", "Nobody Existing")
    assert_nil person
    assert_nil athlete
  end

  # ─── ensure_active_contract ──────────────────────────────────────────────────

  test "ensure_active_contract creates a Contract when player is new to team" do
    person = Person.create!(first_name: "New", last_name: "Signing", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football")

    assert_difference -> { Contract.count }, 1 do
      @service.send(:ensure_active_contract, person, athlete, @bills.slug, "QB")
    end

    contract = Contract.find_by(person_slug: person.slug, team_slug: @bills.slug)
    assert_equal "active", contract.contract_type
    assert_equal "QB", contract.position
    assert_equal 1, @service.stats[:contracts_created]
  end

  test "ensure_active_contract sets Athlete.team_slug" do
    person = Person.create!(first_name: "Team", last_name: "Update", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football")

    @service.send(:ensure_active_contract, person, athlete, @bills.slug, nil)
    assert_equal @bills.slug, athlete.reload.team_slug
    assert_equal 1, @service.stats[:team_slug_updates]
  end

  test "ensure_active_contract is a no-op when player already on team and team_slug current" do
    person = Person.create!(first_name: "Stable", last_name: "Roster", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", team_slug: @bills.slug)
    Contract.create!(person_slug: person.slug, team_slug: @bills.slug, contract_type: "active")

    assert_no_difference -> { Contract.count } do
      @service.send(:ensure_active_contract, person, athlete, @bills.slug, "QB")
    end

    assert_equal 0, @service.stats[:contracts_created]
    assert_equal 0, @service.stats[:contracts_revived]
    assert_equal 0, @service.stats[:contracts_expired]
    assert_equal 0, @service.stats[:team_slug_updates]
  end

  test "ensure_active_contract expires stale contracts on other teams" do
    person = Person.create!(first_name: "Traded", last_name: "Player", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", team_slug: @dolphins.slug)
    old_contract = Contract.create!(person_slug: person.slug, team_slug: @dolphins.slug, contract_type: "active")

    @service.send(:ensure_active_contract, person, athlete, @bills.slug, "QB")

    assert_equal Date.today - 1, old_contract.reload.expires_at
    assert old_contract.expired?
    assert_equal @bills.slug, athlete.reload.team_slug
    assert_equal 1, @service.stats[:contracts_expired]
  end

  test "ensure_active_contract revives an expired contract when player returns" do
    person = Person.create!(first_name: "Returning", last_name: "Vet", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football")
    contract = Contract.create!(person_slug: person.slug, team_slug: @bills.slug,
                                 contract_type: "active", expires_at: Date.today - 30)

    @service.send(:ensure_active_contract, person, athlete, @bills.slug, "QB")

    contract.reload
    assert_nil contract.expires_at
    assert contract.active?
    assert_equal 1, @service.stats[:contracts_revived]
  end

  # ─── Partial response guard ──────────────────────────────────────────────────

  test "scrape_team skips when ESPN returns only some sides (partial response)" do
    chart = DepthChart.find_or_create_by!(team_slug: @bills.slug)
    p = Person.create!(first_name: "Guard", last_name: "Test", athlete: true)
    pre_existing = chart.depth_chart_entries.create!(
      person_slug: p.slug, position: "QB", side: "offense", depth: 1
    )

    # Stub fetch_groups to simulate ESPN's broken Lions response: only defense
    @service.define_singleton_method(:fetch_groups) { |_, _ = nil| [{ "name" => "Base 4-3 D", "rows" => [] }] }
    @service.send(:scrape_team, "buf", @bills.slug)

    assert_equal 1, @service.stats[:teams_partial]
    assert DepthChartEntry.exists?(pre_existing.id), "pre-existing entry should not be touched"
  end

  # ─── DepthChart shell auto-create ────────────────────────────────────────────

  test "scrape_team auto-creates DepthChart shell when missing" do
    DepthChart.where(team_slug: @bills.slug).destroy_all
    refute DepthChart.exists?(team_slug: @bills.slug)

    # The shell is created BEFORE the fetch, so a team ESPN cannot serve still gets
    # its row. fetch_groups is stubbed rather than left to fail: this test used to
    # depend on a LIVE 403 from site.api.espn.com for its nil, which made it a
    # network call that passed for the wrong reason.
    @service.define_singleton_method(:fetch_groups) { |_, _ = nil| nil }
    @service.send(:scrape_team, "buf", @bills.slug)

    assert DepthChart.exists?(team_slug: @bills.slug)
    assert_equal 1, @service.stats[:depth_charts_created]
  end

  # ─── apply_row preserves ESPN's verbatim order ───────────────────────────────

  test "apply_row preserves ESPN order even when interleaving new and existing players" do
    # Reproduces the NE Patriots LT bug: ESPN published [Campbell, Hudson, Lomu, Metz]
    # but the old logic bucketed existing entries before new ones, producing
    # [Hudson, Metz, Campbell, Lomu]. With the fix, ESPN's order is preserved.
    chart = DepthChart.find_or_create_by!(team_slug: @bills.slug)

    # Pre-existing: Hudson + Metz both at LT from a previous seed pass
    hudson = Person.create!(first_name: "James", last_name: "Hudson", athlete: true)
    Athlete.create!(person_slug: hudson.slug, sport: "football", espn_id: "h-1")
    Contract.create!(person_slug: hudson.slug, team_slug: @bills.slug, contract_type: "active")
    chart.depth_chart_entries.create!(person_slug: hudson.slug, position: "LT", side: "offense", depth: 1)

    metz = Person.create!(first_name: "Lorenz", last_name: "Metz", athlete: true)
    Athlete.create!(person_slug: metz.slug, sport: "football", espn_id: "m-1")
    Contract.create!(person_slug: metz.slug, team_slug: @bills.slug, contract_type: "active")
    chart.depth_chart_entries.create!(person_slug: metz.slug, position: "LT", side: "offense", depth: 2)

    # Brand-new: Campbell + Lomu have Athletes but no DepthChartEntry yet
    campbell = Person.create!(first_name: "Will", last_name: "Campbell", athlete: true)
    Athlete.create!(person_slug: campbell.slug, sport: "football", espn_id: "c-1")
    lomu = Person.create!(first_name: "Caleb", last_name: "Lomu", athlete: true)
    Athlete.create!(person_slug: lomu.slug, sport: "football", espn_id: "l-1")

    # Mimic ESPN's row format — espn_id is parsed out of href via /id/(\d+)/
    espn_athletes = [
      { "name" => "Will Campbell",      "href" => "/nfl/player/_/id/c-1/" },
      { "name" => "James Hudson",       "href" => "/nfl/player/_/id/h-1/" },
      { "name" => "Caleb Lomu",         "href" => "/nfl/player/_/id/l-1/" },
      { "name" => "Lorenz Metz",        "href" => "/nfl/player/_/id/m-1/" }
    ]

    @service.send(:apply_row, chart, "LT", "offense", espn_athletes, @bills.slug)

    ordered = chart.depth_chart_entries.where(position: "LT").order(:depth).pluck(:person_slug)
    assert_equal [campbell.slug, hudson.slug, lomu.slug, metz.slug], ordered,
                 "ESPN's order [Campbell, Hudson, Lomu, Metz] must be preserved verbatim"
  end

  # ─── espn_id backfill on name-match ──────────────────────────────────────────

  test "match_person backfills espn_id when athlete was found by name (not id)" do
    person = Person.create!(first_name: "Backfill", last_name: "Target", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football")  # no espn_id

    @service.send(:match_person, { "name" => "Backfill Target", "href" => "/nfl/player/_/id/123456/" }, @bills.slug)

    athlete.reload
    assert_equal "123456", athlete.espn_id
    assert_equal "https://a.espncdn.com/i/headshots/nfl/players/full/123456.png", athlete.espn_headshot_url
    assert_equal 1, @service.stats[:espn_ids_backfilled]
  end

  test "match_person does NOT overwrite an existing espn_id" do
    person = Person.create!(first_name: "Existing", last_name: "Espn", athlete: true)
    athlete = Athlete.create!(person_slug: person.slug, sport: "football", espn_id: "999")

    @service.send(:match_person, { "name" => "Existing Espn", "href" => "/nfl/player/_/id/123456/" }, @bills.slug)

    assert_equal "999", athlete.reload.espn_id
    assert_equal 0, @service.stats[:espn_ids_backfilled]
  end

  test "match_person does NOT backfill if espn_id is already taken by another athlete" do
    other_person = Person.create!(first_name: "Other", last_name: "Owner", athlete: true)
    Athlete.create!(person_slug: other_person.slug, sport: "football", espn_id: "555")

    target_person = Person.create!(first_name: "Wants", last_name: "Espn", athlete: true)
    target_athlete = Athlete.create!(person_slug: target_person.slug, sport: "football")

    @service.send(:match_person, { "name" => "Wants Espn", "href" => "/nfl/player/_/id/555/" }, @bills.slug)

    assert_nil target_athlete.reload.espn_id  # not backfilled because 555 is taken
  end

  # ─── Position reconciliation ─────────────────────────────────────────────────

  test "reconcile_chart_positions moves a 3-4 OLB to EDGE when athlete.position says EDGE" do
    chart = DepthChart.find_or_create_by!(team_slug: @bills.slug)

    # Existing EDGE depth chain: an actual DE at depth 1, another at depth 2
    de1 = Person.create!(first_name: "DE", last_name: "Starter", athlete: true)
    Athlete.create!(person_slug: de1.slug, sport: "football", position: "EDGE")
    chart.depth_chart_entries.create!(person_slug: de1.slug, position: "EDGE", side: "defense", depth: 1)

    de2 = Person.create!(first_name: "DE", last_name: "Backup", athlete: true)
    Athlete.create!(person_slug: de2.slug, sport: "football", position: "EDGE")
    chart.depth_chart_entries.create!(person_slug: de2.slug, position: "EDGE", side: "defense", depth: 2)

    # Crosby-shaped: athlete classified as EDGE but ESPN placed him at LB depth 1
    crosby = Person.create!(first_name: "Maxx", last_name: "Crosby", athlete: true)
    Athlete.create!(person_slug: crosby.slug, sport: "football", position: "EDGE")
    chart.depth_chart_entries.create!(person_slug: crosby.slug, position: "LB", side: "defense", depth: 1)

    @service.send(:reconcile_chart_positions, chart)

    # Crosby moved to EDGE, kept depth 1; existing DEs bumped to 2 and 3
    edge_chain = chart.depth_chart_entries.where(position: "EDGE").order(:depth).pluck(:person_slug)
    assert_equal [crosby.slug, de1.slug, de2.slug], edge_chain

    # LB chain has the Crosby gap (filled by densify_chart in the real flow)
    refute_includes chart.depth_chart_entries.where(position: "LB").pluck(:person_slug), crosby.slug
    assert_equal 1, @service.stats[:positions_reconciled]
  end

  test "reconcile_chart_positions leaves locked entries alone" do
    chart = DepthChart.find_or_create_by!(team_slug: @bills.slug)

    p = Person.create!(first_name: "Locked", last_name: "Edge", athlete: true)
    Athlete.create!(person_slug: p.slug, sport: "football", position: "EDGE")
    chart.depth_chart_entries.create!(person_slug: p.slug, position: "LB", side: "defense", depth: 1, locked: true)

    @service.send(:reconcile_chart_positions, chart)

    assert_equal "LB", chart.depth_chart_entries.find_by(person_slug: p.slug).position
    assert_equal 0, @service.stats[:positions_reconciled]
  end

  test "reconcile_chart_positions drops the misplaced entry when athlete already has one at the canonical position" do
    chart = DepthChart.find_or_create_by!(team_slug: @bills.slug)

    p = Person.create!(first_name: "Twin", last_name: "Defender", athlete: true)
    Athlete.create!(person_slug: p.slug, sport: "football", position: "EDGE")
    canonical_entry = chart.depth_chart_entries.create!(person_slug: p.slug, position: "EDGE", side: "defense", depth: 1)
    misplaced_entry = chart.depth_chart_entries.create!(person_slug: p.slug, position: "LB",   side: "defense", depth: 2)

    @service.send(:reconcile_chart_positions, chart)

    assert DepthChartEntry.exists?(canonical_entry.id),
           "canonical EDGE entry should survive"
    refute DepthChartEntry.exists?(misplaced_entry.id),
           "misplaced LB entry should be deleted"
    assert_equal 1, @service.stats[:positions_deduped]
  end

  test "reconcile_chart_positions moves a 3-4 DE (interior) to DT when athlete.position says DT" do
    # 3-4 schemes: ESPN's LDE/RDE is an interior 5-tech, our taxonomy calls that DT.
    # ESPN_MAP collapses LDE/RDE → EDGE blindly; reconciliation moves them to DT.
    chart = DepthChart.find_or_create_by!(team_slug: @bills.slug)

    p = Person.create!(first_name: "Ed", last_name: "OliverDup", athlete: true)
    Athlete.create!(person_slug: p.slug, sport: "football", position: "DT")
    chart.depth_chart_entries.create!(person_slug: p.slug, position: "EDGE", side: "defense", depth: 1)

    @service.send(:reconcile_chart_positions, chart)

    entry = chart.depth_chart_entries.find_by(person_slug: p.slug)
    assert_equal "DT", entry.position
    assert_equal 1, @service.stats[:positions_reconciled]
  end

  test "reconcile_chart_positions does NOT move CB ↔ S (different reconciliation axis)" do
    chart = DepthChart.find_or_create_by!(team_slug: @bills.slug)

    p = Person.create!(first_name: "Hybrid", last_name: "DB", athlete: true)
    Athlete.create!(person_slug: p.slug, sport: "football", position: "S")
    chart.depth_chart_entries.create!(person_slug: p.slug, position: "CB", side: "defense", depth: 1)

    @service.send(:reconcile_chart_positions, chart)

    # CB↔S is intentionally NOT auto-reconciled (slot CB / big-nickel ambiguity).
    assert_equal "CB", chart.depth_chart_entries.find_by(person_slug: p.slug).position
  end

  test "apply_row prunes stale duplicate entries (post-merge artifact)" do
    chart = DepthChart.find_or_create_by!(team_slug: @bills.slug)

    # Crosby ends up with two entries on the chart after a duplicate-Person
    # merge: one at EDGE, one at LB.
    crosby = Person.create!(first_name: "Maxx", last_name: "CrosbyDup", athlete: true)
    Athlete.create!(person_slug: crosby.slug, sport: "football", espn_id: "mc-1")
    Contract.create!(person_slug: crosby.slug, team_slug: @bills.slug, contract_type: "active")
    chart.depth_chart_entries.create!(person_slug: crosby.slug, position: "EDGE", side: "defense", depth: 5)
    stale = chart.depth_chart_entries.create!(person_slug: crosby.slug, position: "LB", side: "defense", depth: 4)

    # ESPN scrape places Crosby at LB depth 1
    espn_athletes = [{ "name" => "Maxx CrosbyDup", "href" => "/nfl/player/_/id/mc-1/" }]
    @service.send(:apply_row, chart, "LB", "defense", espn_athletes, @bills.slug)

    # The pre-existing LB entry was kept and updated to depth 1; EDGE entry was pruned
    refute DepthChartEntry.exists?(id: chart.depth_chart_entries.find_by(person_slug: crosby.slug, position: "EDGE")&.id),
           "EDGE entry should have been pruned"
    assert_equal 1, chart.depth_chart_entries.find_by(person_slug: crosby.slug, position: "LB").depth
    assert_equal 1, @service.stats[:stale_entries_pruned]
  end

  test "apply_row respects locked entries even when ESPN places someone in the locked depth" do
    chart = DepthChart.find_or_create_by!(team_slug: @bills.slug)

    starter = Person.create!(first_name: "Locked", last_name: "Starter", athlete: true)
    Athlete.create!(person_slug: starter.slug, sport: "football", espn_id: "s-1")
    Contract.create!(person_slug: starter.slug, team_slug: @bills.slug, contract_type: "active")
    chart.depth_chart_entries.create!(person_slug: starter.slug, position: "QB", side: "offense", depth: 1, locked: true)

    backup = Person.create!(first_name: "Espn", last_name: "Newcomer", athlete: true)
    Athlete.create!(person_slug: backup.slug, sport: "football", espn_id: "n-1")

    espn_athletes = [{ "name" => "Espn Newcomer", "href" => "/nfl/player/_/id/n-1/" }]
    @service.send(:apply_row, chart, "QB", "offense", espn_athletes, @bills.slug)

    # Locked starter held depth 1; backup got the next free slot.
    assert_equal starter.slug, chart.depth_chart_entries.find_by(position: "QB", depth: 1).person_slug
    assert_equal backup.slug,  chart.depth_chart_entries.find_by(position: "QB", depth: 2).person_slug
  end

  # ─── the host and the user agent that must not drift back ────────────────────

  test "the roster and the teams index are fetched from the host that serves Ruby" do
    roster = Espn::ScrapeDepthCharts::ESPN_ROSTER_URL.call("13")

    assert_includes roster, "site.web.api.espn.com"
    assert_includes Espn::ScrapeDepthCharts::ESPN_TEAMS_INDEX_URL, "site.web.api.espn.com"

    # Anchored on `//` so the refutation is about the AUTHORITY and cannot be
    # satisfied by a path that merely mentions the host, matching the assertion
    # Espn::PlayerProfileTest already makes about the same mistake.
    refute_includes roster, "//site.api.espn.com"
    refute_includes Espn::ScrapeDepthCharts::ESPN_TEAMS_INDEX_URL, "//site.api.espn.com"
  end

  test "the depth chart endpoint keeps the core host, which never filtered" do
    # sports.core.api.espn.com was never the bug — measured 2026-09-27 it answered
    # 200 to Net::HTTP for all 32 team ids. Moving it would be a fix to nothing.
    assert_includes Espn::ScrapeDepthCharts::ESPN_DEPTHCHART_URL.call(2026, "13"),
                    "sports.core.api.espn.com"
  end

  test "the user agent names this app and does not impersonate a browser" do
    ua = Espn::ScrapeDepthCharts::USER_AGENT

    refute_match(/Mozilla|Chrome|Safari|AppleWebKit/, ua,
                 "site.api rejected the Chrome string and admitted curl — impersonation " \
                 "made this worse, not better")
    assert_includes ua, "mcritchie-studio"
  end

  test "the host and the user agent are the shared ones, not a second copy" do
    # A SECOND DIVERGENT COPY IS HOW THIS BUG HAPPENED. Espn::PlayerProfile already
    # carried the working host and an honest UA while this service carried the dead
    # host and a Chrome string, in the same directory, for weeks.
    assert_equal Espn::Api::USER_AGENT, Espn::ScrapeDepthCharts::USER_AGENT
    assert_includes Espn::ScrapeDepthCharts::ESPN_TEAMS_INDEX_URL, Espn::Api::WEB_HOST
    assert_includes Espn::PlayerProfile::ROSTER_URL, Espn::Api::WEB_HOST
  end

  # ─── fetch_json tells "no such thing" apart from "could not answer" ──────────

  test "fetch_json returns nil for a 404 and raises for every other non-success" do
    service = Espn::ScrapeDepthCharts.new

    assert_nil service.send(:parse_response, stub_response(Net::HTTPNotFound, "404"), URI(TEAMS_INDEX)),
               "a 404 is ESPN saying there is no such document — the season fallback needs that nil"

    [[Net::HTTPForbidden, "403"], [Net::HTTPInternalServerError, "500"], [Net::HTTPBadGateway, "502"]].each do |klass, code|
      error = assert_raises(Espn::ScrapeDepthCharts::SourceUnavailable) do
        service.send(:parse_response, stub_response(klass, code), URI(TEAMS_INDEX))
      end
      assert_includes error.message, code, "the code ESPN answered has to survive into the message"
    end
  end

  # ─── a team that yields no id fails loudly ──────────────────────────────────

  test "a run raises when ESPN's index carries no id for a team it was asked to scrape" do
    # THE 28-OF-32 DEFECT. A missing id used to print one line, tally teams_failed,
    # and let the other teams through, so the lane stayed green while a chart went
    # a week stale. Our abbrev map disagreeing with ESPN's index is a code fault,
    # not weather, and it cannot heal on the next run.
    short = Espn::ScrapeDepthCharts::TEAM_ABBREV_TO_SLUG.keys - %w[lv sea]
    service = Stubbed.new({ TEAMS_INDEX => teams_index(short.each_with_index.to_h { |a, i| [a, (i + 1).to_s] }) })

    error = assert_raises(Espn::ScrapeDepthCharts::MissingTeamId) { service.call }

    assert_includes error.message, "lv"
    assert_includes error.message, "sea"
    assert_includes error.message, "30", "the size of the index ESPN actually served"
  end

  test "the missing id is caught before any chart is touched" do
    # Failing AFTER applying 31 teams would leave a half-refreshed league behind a
    # non-zero exit, which is the worst of both. Every id is resolved first.
    DepthChart.where(team_slug: @bills.slug).destroy_all
    short = Espn::ScrapeDepthCharts::TEAM_ABBREV_TO_SLUG.keys - %w[sea]
    service = Stubbed.new({ TEAMS_INDEX => teams_index(short.each_with_index.to_h { |a, i| [a, (i + 1).to_s] }) })

    assert_raises(Espn::ScrapeDepthCharts::MissingTeamId) { service.call }

    refute DepthChart.exists?(team_slug: @bills.slug),
           "no team may be scraped until every id this run needs has resolved"
    assert_equal 1, service.requested.length, "only the index should have been asked for"
  end

  test "a single-team run only demands the id for the team it was asked for" do
    # TEAM=buf must stay usable when ESPN's index is missing some OTHER team, or the
    # guard turns a one-team refresh into a hostage of the whole league.
    index = teams_index({ "buf" => "2" })
    service = Stubbed.new(index_and_buffalo(index), team_abbrev: "buf")

    service.call

    assert_equal 1, service.stats[:teams_scraped]
    assert_equal 0, service.stats[:teams_failed]
  end

  test "an unreadable teams index raises instead of blaming 32 abbreviations" do
    # THE LIE THIS REPLACES: the index 403ed, `body&.dig(...) || []` made an empty
    # map, and the log said "No ESPN team_id for abbrev" 32 times — a statement
    # about OUR data when the fact was that ESPN could not be reached.
    service = Stubbed.new({ TEAMS_INDEX => Espn::ScrapeDepthCharts::SourceUnavailable.new("ESPN answered 403 for site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams") })

    error = assert_raises(Espn::ScrapeDepthCharts::SourceUnavailable) { service.call }

    assert_includes error.message, "403"
    refute_match(/no espn team_id/i, error.message,
                 "an unreachable index is not a missing abbreviation")
  end

  test "a 404 on the teams index is an outage, not a fault in our abbreviation map" do
    # fetch_json answers nil for a 404 because the season fallback needs that nil.
    # The index is the one document where nil must NOT flow on: an empty abbrev map
    # would accuse TEAM_ABBREV_TO_SLUG of being wrong about all 32 teams when the
    # fact is that ESPN served nothing. MEASURED as uncovered by a mutation pass —
    # restoring `body&.dig(...) || []` here reddened nothing until this test existed.
    service = Stubbed.new({ TEAMS_INDEX => nil })

    error = assert_raises(Espn::ScrapeDepthCharts::SourceUnavailable) { service.call }

    assert_includes error.message, TEAMS_INDEX
    refute_kind_of Espn::ScrapeDepthCharts::MissingTeamId, error,
                   "ESPN serving nothing is not our map disagreeing with it"
  end

  test "an index whose shape moved raises instead of reporting an empty league" do
    service = Stubbed.new({ TEAMS_INDEX => { "sports" => [{ "leagues" => [{ "teams" => "nope" }] }] } })

    error = assert_raises(Espn::ScrapeDepthCharts::SourceUnavailable) { service.call }
    assert_match(/shape|expected/i, error.message)
  end

  test "a missing id escapes the per-team rescue instead of becoming one more failure" do
    # THE GUARD THIS COVERS: fetch_groups wraps everything in `rescue StandardError`
    # so one dead team cannot cost the other 31. Without the explicit re-raise,
    # MissingTeamId lands in that rescue and the fault in our own map is laundered
    # into a tolerated team — the exact silence this task exists to remove. Reached
    # through scrape_team, which is the entry point when a caller drives one team.
    service = Stubbed.new({ TEAMS_INDEX => teams_index({ "mia" => "15" }) })

    error = assert_raises(Espn::ScrapeDepthCharts::MissingTeamId) do
      service.send(:scrape_team, "buf", @bills.slug)
    end

    assert_includes error.message, "buf"
    assert_equal 0, service.stats[:teams_failed],
                 "a fault in our map must not be counted as a team ESPN could not serve"
  end

  # ─── the green twin: per-team tolerance survives ────────────────────────────

  test "a team whose depth chart ESPN cannot serve is tolerated and tallied" do
    # A GUARD THAT REFUSED EVERY DEGRADED RUN would pass every case above and is
    # caught here. One dead team is a normal ESPN afternoon; the LANE grades the
    # tally (lib/tasks/espn.rake), the service keeps its per-team tolerance.
    index = teams_index({ "buf" => "2" })
    responses = { TEAMS_INDEX => index }
    responses[Espn::ScrapeDepthCharts::ESPN_ROSTER_URL.call("2")] = { "athletes" => [] }
    responses[Espn::ScrapeDepthCharts::ESPN_DEPTHCHART_URL.call(nfl_year, "2")] =
      Espn::ScrapeDepthCharts::SourceUnavailable.new("ESPN answered 503 for sports.core.api.espn.com")
    responses[Espn::ScrapeDepthCharts::ESPN_DEPTHCHART_URL.call(nfl_year - 1, "2")] =
      Espn::ScrapeDepthCharts::SourceUnavailable.new("ESPN answered 503 for sports.core.api.espn.com")
    service = Stubbed.new(responses, team_abbrev: "buf")

    stats = service.call

    assert_equal 1, stats[:teams_failed], "the team is counted, not raised over"
    assert_equal 0, stats[:teams_scraped]
  end

  # ─── the cause of a tolerated failure ───────────────────────────────────────
  #
  # MEASURED on this branch's parent (6dbc6a93^): `grep -rE "ErrorLog|rescue_and_log"
  # app/services/espn/ lib/tasks/espn.rake` returned ZERO hits, so the `puts` in
  # fetch_groups' rescue was the whole record of a dead team — and
  # bin/ecosystem-build runs the lane as
  # `bundle exec rails espn:scrape_depth_charts >/dev/null`, which throws that away.

  test "a tolerated per-team fetch failure files an ErrorLog carrying the cause" do
    service = Stubbed.new(buffalo_with_dead_depth_chart, team_abbrev: "buf")

    assert_difference -> { ErrorLog.count }, 1 do
      service.call
    end

    row = ErrorLog.order(:id).last
    assert_match(/503/, row.message, "the row must carry WHY, not just that something failed")
    assert_match(/SourceUnavailable/, row.inspect_field)
    assert_equal DepthChart.find_by(team_slug: @bills.slug), row.target,
                 "the chart is the target so /admin/error_logs renders the team on the row"
    assert_equal "#{@bills.slug}-depth", row.target_name
    assert row.slug.present?,
           "a row with no slug is unreachable in /admin/error_logs — invisible to the " \
           "person it was written for"
  end

  test "the run is still tolerated and tallied once the row is filed" do
    # THE ROW MUST NOT COST THE OTHER 31 TEAMS THEIR REFRESH. A guard that filed by
    # re-raising (rescue_and_log's shape) would pass the case above and is caught here.
    service = Stubbed.new(buffalo_with_dead_depth_chart, team_abbrev: "buf")

    stats = service.call

    assert_equal 1, stats[:teams_failed]
    assert_equal 0, stats[:teams_scraped]
  end

  test "a healthy team files no ErrorLog row at all" do
    # THE GREEN TWIN. A row on every run is not a signal.
    service = Stubbed.new(index_and_buffalo(teams_index({ "buf" => "2" })), team_abbrev: "buf")

    assert_no_difference -> { ErrorLog.count } do
      service.call
    end
  end

  test "a depth chart ESPN does not publish is tallied and files NO row" do
    # A DEAD SOURCE IS NOT OUR FAILURE — the distinction Athletes::DeadHeadshotSource
    # draws for the headshot lane, drawn here one layer lower by parse_response, which
    # turns a 404 into a nil and every other non-success into a raise. Both seasons
    # answer 404, so fetch_groups returns nil WITHOUT raising and the row is not
    # filed; the team is still counted. This is why the row belongs in the rescue and
    # not in scrape_team's `unless groups`, which both cases reach.
    responses = { TEAMS_INDEX => teams_index({ "buf" => "2" }) }
    responses[Espn::ScrapeDepthCharts::ESPN_ROSTER_URL.call("2")] = { "athletes" => [] }
    responses[Espn::ScrapeDepthCharts::ESPN_DEPTHCHART_URL.call(nfl_year, "2")] = nil
    responses[Espn::ScrapeDepthCharts::ESPN_DEPTHCHART_URL.call(nfl_year - 1, "2")] = nil
    service = Stubbed.new(responses, team_abbrev: "buf")

    assert_no_difference -> { ErrorLog.count } do
      assert_equal 1, service.call[:teams_failed]
    end
  end

  test "a fault in our own abbreviation map is not filed as a tolerated team" do
    # MissingTeamId is re-raised through the per-team rescue WITHOUT a row, so the one
    # exception the lane's own rescue will file cannot be filed twice.
    service = Stubbed.new({ TEAMS_INDEX => teams_index({ "mia" => "15" }) })

    assert_no_difference -> { ErrorLog.count } do
      assert_raises(Espn::ScrapeDepthCharts::MissingTeamId) { service.call }
    end
  end

  # ─── no credential can reach a durable row ──────────────────────────────────

  test "no ESPN service reads a credential, so no ErrorLog row can carry one" do
    # WHY THIS IS A REAL RISK AND NOT DECORATION: fetch_json's SourceUnavailable
    # message ends "for #{url_str}", that exception is what the rescue above files,
    # and error_logs is a durable table that also fans out to Sentry. A key in a query
    # string would therefore be written down permanently. Every ESPN endpoint this app
    # reads is public and takes no key (measured 2026-09-27, recorded on Espn::Api),
    # so the guard is that it STAYS that way.
    #
    # Flattened after dropping whole-line comments, not matched line by line: a
    # multi-line string or a wrapped argument list puts the two halves of a read on
    # different lines, and a line regex sees neither. Comments are dropped because the
    # sentence you are reading names the literal it forbids; a trailing comment can
    # only produce a FALSE POSITIVE here, which is the safe direction for a guard.
    forbidden = ["ENV[", "Rails.application.credentials", "api_key", "access_token", "Bearer "]
    Dir[Rails.root.join("app/services/espn/**/*.rb")].sort.each do |path|
      code = File.readlines(path).reject { |line| line.strip.start_with?("#") }.join(" ").squeeze(" ")
      forbidden.each do |needle|
        assert_not code.include?(needle),
                   "#{Pathname.new(path).relative_path_from(Rails.root)} reads #{needle.inspect}. " \
                   "The ESPN lane is credential-free by design and its exceptions are filed " \
                   "verbatim into error_logs (durable, and forwarded to Sentry) — a secret " \
                   "reaching a message here cannot be taken back."
      end
    end
  end

  private

  # Buffalo's index and roster read cleanly and BOTH seasons' depth chart documents
  # answer 503 — a team ESPN could not serve, which is the tolerated case.
  def buffalo_with_dead_depth_chart
    responses = { TEAMS_INDEX => teams_index({ "buf" => "2" }) }
    responses[Espn::ScrapeDepthCharts::ESPN_ROSTER_URL.call("2")] = { "athletes" => [] }
    [nfl_year, nfl_year - 1].each do |year|
      responses[Espn::ScrapeDepthCharts::ESPN_DEPTHCHART_URL.call(year, "2")] =
        Espn::ScrapeDepthCharts::SourceUnavailable.new("ESPN answered 503 for sports.core.api.espn.com")
    end
    responses
  end

  def nfl_year
    today = Date.current
    today.month <= 2 ? today.year - 1 : today.year
  end

  # A real Net::HTTPResponse subclass with a body already "read" — the standard way
  # to hand Net::HTTP's own is_a? checks something to judge.
  def stub_response(klass, code, body = "{}")
    res = klass.new("1.1", code, "stub")
    res.instance_variable_set(:@body, body)
    res.instance_variable_set(:@read, true)
    res
  end

  # Index plus the two documents a healthy Buffalo scrape reads: a roster (for the
  # id => name map) and a depth chart carrying all three sides.
  def index_and_buffalo(index)
    {
      TEAMS_INDEX => index,
      Espn::ScrapeDepthCharts::ESPN_ROSTER_URL.call("2") => {
        "athletes" => [{ "position" => "offense", "items" => [{ "id" => "3139477", "displayName" => "Buffalo Passer" }] }]
      },
      Espn::ScrapeDepthCharts::ESPN_DEPTHCHART_URL.call(nfl_year, "2") => {
        "items" => [
          { "name" => "3WR 1TE 1RB", "positions" => { "qb" => { "position" => { "abbreviation" => "QB" },
            "athletes" => [{ "slot" => 1, "athlete" => { "$ref" => "https://sports.core.api.espn.com/v2/sports/football/leagues/nfl/athletes/3139477?lang=en" } }] } } },
          { "name" => "Base 4-3 D", "positions" => {} },
          { "name" => "Special Teams", "positions" => {} }
        ]
      }
    }
  end
end
