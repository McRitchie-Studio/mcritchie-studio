require "test_helper"

# THE ESPN PROVIDER'S TRANSLATION AND ITS TRAPS.
#
# The HTTP is stubbed at #fetch_json by a subclass rather than by a mocking library,
# because this suite has none — and because naming the exact URLs keeps the test
# honest about WHICH endpoint each behaviour belongs to. The URL constants are
# asserted directly in their own test, since one of them (the roster host) is the
# difference between this provider working and 403ing.
class Espn::PlayerProfileTest < ActiveSupport::TestCase
  # A provider whose only difference is where the bytes come from.
  class Stubbed < Espn::PlayerProfile
    attr_reader :requested

    def initialize(responses)
      super()
      @responses = responses
      @requested = []
    end

    private

    def fetch_json(url)
      @requested << url
      raise "unstubbed request: #{url}" unless @responses.key?(url)

      value = @responses.fetch(url)
      raise value if value.is_a?(StandardError)

      value
    end
  end

  ROSTER_LV = "https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams/lv/roster".freeze
  ATHLETE = "https://site.web.api.espn.com/apis/common/v3/sports/football/nfl/athletes/%s".freeze

  # The real roster's shape: SIX GROUPS, players underneath. Measured for Las Vegas
  # on 2026-09-27 — athletes.size was 6 and the players numbered 79.
  def roster_body(groups)
    { "athletes" => groups.map { |name, items| { "position" => name, "items" => items } } }
  end

  def player(id, name, jersey, position)
    { "id" => id, "displayName" => name, "jersey" => jersey,
      "position" => { "abbreviation" => position } }
  end

  def athlete_body(overrides = {})
    { "athlete" => {
      "id" => "4890973", "displayName" => "Ashton Jeanty", "firstName" => "Ashton",
      "lastName" => "Jeanty", "jersey" => "2", "height" => nil, "displayHeight" => "5' 8\"",
      "weight" => nil, "displayWeight" => "208 lbs",
      "position" => { "abbreviation" => "RB" },
      "team" => { "slug" => "las-vegas-raiders", "abbreviation" => "LV" },
      "college" => { "name" => "Boise State" }
    }.merge(overrides) }
  end

  # ─── the host that must not drift back ──────────────────────────────────────

  test "the roster is fetched from the host that serves Ruby" do
    # Measured 2026-09-27 over 18 requests: site.api.espn.com answers 403 to every
    # User-Agent Net::HTTP can send (including a Chrome string) and 200 to curl,
    # while site.web.api.espn.com serves the IDENTICAL document to any UA. curl
    # "proving" the endpoint works is what put the wrong host in the task brief, so
    # the host is pinned by an assertion and not only by a comment.
    assert_includes Espn::PlayerProfile::ROSTER_URL, "site.web.api.espn.com"
    refute_includes Espn::PlayerProfile::ROSTER_URL, "//site.api.espn.com"
    refute_match(/Mozilla|Chrome|Safari/, Espn::PlayerProfile::USER_AGENT,
                 "impersonating a browser is what the roster host rejects")
  end

  # ─── the grouped roster ─────────────────────────────────────────────────────

  test "roster flattens the six groups into players" do
    provider = Stubbed.new(ROSTER_LV => roster_body(
      "offense" => [player("1", "Ashton Jeanty", "2", "RB"), player("2", "Brock Bowers", "89", "TE")],
      "defense" => [player("3", "Maxx Crosby", "98", "DE")],
      "specialTeam" => [player("4", "AJ Cole", "6", "P")],
      "injuredReserveOrOut" => [player("5", "Keyron Crawford", "42", "DE")],
      "suspended" => [],
      "practiceSquad" => [player("6", "Patrick Gurd", "45", "TE")]
    ))

    entries = provider.roster(team: "lv")

    # SIX is the number of GROUPS. A naive read of `athletes[]` returns exactly that
    # and finds no players at all, without raising.
    assert_equal 6, entries.length, "one entry per PLAYER, not per group"
    assert_equal %w[1 2 3 4 5 6], entries.map(&:source_id)
    assert_equal "practiceSquad", entries.last.group, "the group is carried through"
    assert_equal 2, entries.first.jersey_number
  end

  test "roster normalizes each position through the ESPN map" do
    provider = Stubbed.new(ROSTER_LV => roster_body(
      "defense" => [player("3", "Maxx Crosby", "98", "DE"), player("7", "Devin White", "0", "OLB")]
    ))

    entries = provider.roster(team: "lv")

    assert_equal "EDGE", entries.first.position, "ESPN_MAP sends DE to EDGE"
    assert_equal "LB", entries.last.position, "ESPN_MAP sends OLB to LB"
    assert_equal 0, entries.last.jersey_number, "jersey 0 survives as a number"
  end

  test "a roster whose athletes key is not grouped raises instead of reporting nobody" do
    # The failure mode this guards: an empty roster makes every lookup answer "not on
    # this team", so a shape change would file honest-looking refusals about 79 people.
    provider = Stubbed.new(ROSTER_LV => { "athletes" => { "offense" => [] } })

    error = assert_raises(Athletes::SourceUnavailable) { provider.roster(team: "lv") }
    assert_match(/not grouped as expected/, error.message)
  end

  test "roster memoizes so a league walk pays for each team once" do
    provider = Stubbed.new(ROSTER_LV => roster_body("offense" => [player("1", "A B", "2", "RB")]))

    3.times { provider.roster(team: "lv") }

    assert_equal 1, provider.requested.length
  end

  test "roster requires a team" do
    assert_raises(ArgumentError) { Espn::PlayerProfile.new.roster(team: "") }
  end

  # ─── the athlete document ───────────────────────────────────────────────────

  test "find parses the display strings the numeric fields leave empty" do
    provider = Stubbed.new(format(ATHLETE, "4890973") => athlete_body)

    profile = provider.find(source_id: "4890973")

    assert_equal :espn, profile.source
    assert_equal "4890973", profile.source_id
    assert_equal "Ashton Jeanty", profile.full_name
    assert_equal 2, profile.jersey_number
    assert_equal "RB", profile.position
    assert_equal 68, profile.height_inches, "parsed from \"5' 8\\\"\" with height nil"
    assert_equal 208, profile.weight_lbs
    assert_equal "Boise State", profile.college
    assert_equal "https://a.espncdn.com/i/headshots/nfl/players/full/4890973.png", profile.headshot_url
    assert_empty profile.unparsed
    assert profile.identified?
  end

  test "find records a display string it could not read rather than dropping it" do
    body = athlete_body
    body["athlete"]["displayHeight"] = "about six foot"
    provider = Stubbed.new(format(ATHLETE, "4890973") => body)

    profile = provider.find(source_id: "4890973")

    assert_nil profile.height_inches
    assert_equal "about six foot", profile.unparsed["height_inches"]
    refute profile.unparsed.key?("weight_lbs"), "a field that parsed is not reported unreadable"
  end

  test "find leaves a genuinely absent field out of unparsed" do
    body = athlete_body
    body["athlete"]["displayHeight"] = nil
    provider = Stubbed.new(format(ATHLETE, "4890973") => body)

    profile = provider.find(source_id: "4890973")

    assert_nil profile.height_inches
    assert_empty profile.unparsed, "absent and unreadable are different facts"
  end

  test "find returns nil for an id the source does not carry" do
    provider = Stubbed.new(format(ATHLETE, "999") => nil)

    assert_nil provider.find(source_id: "999")
  end

  test "find returns nil without asking when given no id" do
    provider = Stubbed.new({})

    assert_nil provider.find(source_id: nil)
    assert_nil provider.find(source_id: "  ")
    assert_empty provider.requested
  end

  # ─── team resolution ────────────────────────────────────────────────────────

  test "the team slug must exist in teams, or it is not written" do
    # athletes.team_slug is a foreign key by slug with no database constraint, so a
    # slug with no row behind it resolves to nil everywhere — including in
    # Athlete#headshot_key_prefix, which would then file the headshot under
    # free-agents/ for a rostered player.
    body = athlete_body("team" => { "slug" => "las-vegas-invented", "abbreviation" => "ZZZ" })
    provider = Stubbed.new(format(ATHLETE, "4890973") => body)

    assert_nil provider.find(source_id: "4890973").team_slug
  end

  test "an unknown slug falls back to the abbreviation map" do
    teams(:buffalo_bills)
    body = athlete_body("team" => { "slug" => "buffalo-bills-typo", "abbreviation" => "BUF" })
    provider = Stubbed.new(format(ATHLETE, "4890973") => body)

    assert_equal "buffalo-bills", provider.find(source_id: "4890973").team_slug
  end

  test "no team at all is a free agent, not an error" do
    body = athlete_body("team" => nil)
    provider = Stubbed.new(format(ATHLETE, "4890973") => body)

    assert_nil provider.find(source_id: "4890973").team_slug
  end

  # ─── searching by name ──────────────────────────────────────────────────────

  test "find_on_roster matches across a punctuation difference" do
    provider = Stubbed.new(
      ROSTER_LV => roster_body("specialTeam" => [player("3686689", "AJ Cole", "6", "P")]),
      format(ATHLETE, "3686689") => athlete_body("id" => "3686689", "displayName" => "AJ Cole",
                                                 "firstName" => "AJ", "lastName" => "Cole")
    )

    assert_equal "3686689", provider.find_on_roster(team: "lv", name: "A.J. Cole").source_id
  end

  test "find_on_roster returns nil for a name the roster does not carry" do
    provider = Stubbed.new(ROSTER_LV => roster_body("offense" => [player("1", "Ashton Jeanty", "2", "RB")]))

    assert_nil provider.find_on_roster(team: "lv", name: "Bo Nix")
  end

  # ─── the league walk ────────────────────────────────────────────────────────

  test "find_in_league walks rosters until it finds the man" do
    responses = Espn::PlayerProfile::TEAM_ABBREVS.to_h do |abbr|
      body = abbr == "den" ? roster_body("offense" => [player("4426338", "Bo Nix", "10", "QB")]) : roster_body({})
      ["https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams/#{abbr}/roster", body]
    end
    responses[format(ATHLETE, "4426338")] =
      athlete_body("id" => "4426338", "displayName" => "Bo Nix", "firstName" => "Bo", "lastName" => "Nix")
    provider = Stubbed.new(responses)

    assert_equal "4426338", provider.find_in_league(name: "Bo Nix").source_id
  end

  test "find_in_league refuses to conclude absence from an incomplete search" do
    # "He is on no roster in the league" and "I could not read four rosters" are
    # different facts, and the caller turns nil into "retired or released".
    responses = Espn::PlayerProfile::TEAM_ABBREVS.to_h do |abbr|
      url = "https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams/#{abbr}/roster"
      [url, abbr == "lv" ? Espn::PlayerProfile::SourceUnavailable.new("503") : roster_body({})]
    end
    provider = Stubbed.new(responses)

    error = assert_raises(Athletes::SourceUnavailable) { provider.find_in_league(name: "Nobody Here") }
    assert_match(/could not read 1 roster/, error.message)
    assert_match(/not concluding they are unrostered/, error.message)
  end

  test "find_in_league returns nil after a complete search finds nobody" do
    responses = Espn::PlayerProfile::TEAM_ABBREVS.to_h do |abbr|
      ["https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams/#{abbr}/roster", roster_body({})]
    end
    provider = Stubbed.new(responses)

    assert_nil provider.find_in_league(name: "Nobody Here")
  end

  test "find_in_league asks nothing for an empty name" do
    provider = Stubbed.new({})

    assert_nil provider.find_in_league(name: "  ")
    assert_empty provider.requested
  end

  # ─── the rosters the walk could not read ────────────────────────────────────

  test "an unreadable roster is filed even when the man is found on a later one" do
    # THE BRANCH THAT USED TO DESTROY ITS OWN EVIDENCE. `unreadable` was built and then
    # dropped the moment the search succeeded — not printed, not raised, not counted —
    # so a walk over 32 rosters with four of them down reported a clean success and
    # nothing anywhere recorded the outage. "buf" sorts before "den" in TEAM_ABBREVS,
    # so the dead roster is read BEFORE the hit.
    provider = Stubbed.new(league_finding_bo_nix(dead: "buf"))

    assert_difference -> { ErrorLog.count }, 1 do
      assert_equal "4426338", provider.find_in_league(name: "Bo Nix").source_id
    end

    row = ErrorLog.order(:id).last
    assert_match(/could not read 1 roster/, row.message)
    assert_match(/buf/, row.message, "the row must name WHICH roster")
    assert_match(/503/, row.message, "and WHY it could not be read")
    assert row.slug.present?, "a row with no slug is unreachable in /admin/error_logs"
  end

  test "a complete search that finds the man files nothing" do
    # THE GREEN TWIN. A guard that filed on every walk would pass the case above.
    provider = Stubbed.new(league_finding_bo_nix)

    assert_no_difference -> { ErrorLog.count } do
      assert_equal "4426338", provider.find_in_league(name: "Bo Nix").source_id
    end
  end

  test "a complete search that finds nobody files nothing" do
    responses = Espn::PlayerProfile::TEAM_ABBREVS.to_h do |abbr|
      ["https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams/#{abbr}/roster", roster_body({})]
    end

    assert_no_difference -> { ErrorLog.count } do
      assert_nil Stubbed.new(responses).find_in_league(name: "Nobody Here")
    end
  end

  test "the census is filed on the raising branch too" do
    # The raise reaches Athletes::AcquireOrValidate#call, which turns
    # Athletes::SourceUnavailable into a PRINTED refusal — so without the row the cause
    # of an incomplete search lives on stdout, which is where this whole task started.
    responses = Espn::PlayerProfile::TEAM_ABBREVS.to_h do |abbr|
      url = "https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams/#{abbr}/roster"
      [url, abbr == "lv" ? Espn::PlayerProfile::SourceUnavailable.new("503") : roster_body({})]
    end

    assert_difference -> { ErrorLog.count }, 1 do
      assert_raises(Athletes::SourceUnavailable) { Stubbed.new(responses).find_in_league(name: "Nobody Here") }
    end

    assert_match(/could not read 1 roster\(s\): lv \(503\)/, ErrorLog.order(:id).last.message)
  end

  test "one row per walk, not one per dead roster" do
    # 32 rows saying "ESPN is down" is the noise that teaches an operator to stop
    # opening /admin/error_logs. The census is the finding.
    responses = Espn::PlayerProfile::TEAM_ABBREVS.to_h do |abbr|
      url = "https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams/#{abbr}/roster"
      [url, Espn::PlayerProfile::SourceUnavailable.new("503")]
    end

    assert_difference -> { ErrorLog.count }, 1 do
      assert_raises(Athletes::SourceUnavailable) { Stubbed.new(responses).find_in_league(name: "Bo Nix") }
    end

    assert_match(/could not read 32 roster/, ErrorLog.order(:id).last.message)
  end

  test "a failure on the athlete document is not written down as a roster failure" do
    # THE MISLABEL THIS BRANCH CORRECTS. `return find(source_id: …)` used to sit INSIDE
    # the block the per-team rescue guards, so a 503 on the ATHLETE endpoint was caught
    # and recorded as "could not read roster den" — a sentence about the wrong
    # endpoint, which then became the raise's entire explanation. Every roster here
    # reads cleanly; only the athlete document is down.
    responses = league_finding_bo_nix
    responses[format(ATHLETE, "4426338")] = Espn::PlayerProfile::SourceUnavailable.new("ESPN answered 503 for athletes/4426338")
    provider = Stubbed.new(responses)

    error = assert_no_difference -> { ErrorLog.count } do
      assert_raises(Athletes::SourceUnavailable) { provider.find_in_league(name: "Bo Nix") }
    end

    assert_match(/athletes\/4426338/, error.message)
    assert_no_match(/could not read/, error.message,
                    "no roster failed — saying one did points the operator at the wrong endpoint")
  end

  private

  # Every roster readable and Bo Nix on Denver's, with his athlete document stubbed.
  # `dead:` makes ONE roster answer 503 instead.
  def league_finding_bo_nix(dead: nil)
    responses = Espn::PlayerProfile::TEAM_ABBREVS.to_h do |abbr|
      url = "https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/teams/#{abbr}/roster"
      body = if abbr == dead
               Espn::PlayerProfile::SourceUnavailable.new("503")
             elsif abbr == "den"
               roster_body("offense" => [player("4426338", "Bo Nix", "10", "QB")])
             else
               roster_body({})
             end
      [url, body]
    end
    responses[format(ATHLETE, "4426338")] =
      athlete_body("id" => "4426338", "displayName" => "Bo Nix", "firstName" => "Bo", "lastName" => "Nix")
    responses
  end
end
