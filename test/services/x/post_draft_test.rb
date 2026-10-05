require "test_helper"

# [unit] X::PostDraft — "this team won" in, post copy out. Every ESPN read is a
# fixture here, so these pin the RECIPE: what the copy says, which slot tag a
# kickoff earns, and what stops a person before a false post goes out.
class X::PostDraftTest < ActiveSupport::TestCase
  CHIEFS = X::PostDraft::Team.new(name: "Kansas City Chiefs", location: "Kansas City", mascot: "Chiefs", hashtag: "#ChiefsKingdom")
  NOW    = Time.utc(2026, 10, 5, 4, 0)

  def fetch(record: "4-0", kickoff: "2026-10-04T20:25Z", won: true, events: nil, teams: nil)
    lambda do |url|
      case url
      when %r{/teams\z}
        { "sports" => [{ "leagues" => [{ "teams" => teams || [{ "team" => { "id" => "12", "displayName" => "Kansas City Chiefs" } },
                                                              { "team" => { "id" => "25", "displayName" => "San Francisco 49ers" } }] }] }] }
      when %r{/teams/\d+\z} then { "team" => { "record" => { "items" => [{ "summary" => record }] } } }
      when %r{/schedule\z}
        id = url[%r{/teams/(\d+)/}, 1]
        { "events" => events || [
          { "date" => "2026-09-27T17:00Z", "shortName" => "OLD @ GAME", "competitions" => [competition(id, true, 24, 10)] },
          { "date" => kickoff, "shortName" => "KC @ LV", "competitions" => [competition(id, won, 30, 27)] },
          { "date" => "2026-10-11T17:00Z", "shortName" => "NEXT @ KC", "competitions" => [competition(id, nil, nil, nil, completed: false)] }
        ] }
      end
    end
  end

  def competition(id, won, ours, theirs, completed: true)
    { "neutralSite" => false, "status" => { "type" => { "completed" => completed } },
      "competitors" => [{ "winner" => won, "score" => { "displayValue" => ours.to_s }, "team" => { "id" => id } },
                        { "winner" => won.nil? ? nil : !won, "score" => { "displayValue" => theirs.to_s },
                          "team" => { "id" => "13", "displayName" => "Las Vegas Raiders" } }] }
  end

  def draft(team: CHIEFS, **opts)
    X::PostDraft.new(team: team, fetch: fetch(**opts), now: NOW).call
  end

  test "writes the hook, the league tags, the slogan, the city and the team" do
    result = draft

    assert_equal "Chiefs 4-0 #nfl #nflfootball #chiefskingdom #kansascity #chiefs", result.text
    assert_empty result.exceptions
    assert_empty X::Caption.new(line: result.text).problems
  end

  test "records what it read and where, from the latest FINISHED game" do
    facts = draft.facts

    assert_equal "4-0", facts["record"]
    assert_equal "KC @ LV", facts.dig("last_final", "matchup")
    assert_equal "30-27", facts.dig("last_final", "score")
    assert_equal true, facts.dig("last_final", "won")
    assert_includes facts["source"], "site.web.api.espn.com"
    assert_equal "2026-10-05T04:00:00Z", facts["read_at"]
  end

  test "a prime-time kickoff earns its slot tag and an afternoon one earns none" do
    assert_match(/ #snf\z/, draft(kickoff: "2026-10-05T00:20Z").text)   # Sunday 8:20pm ET
    assert_match(/ #mnf\z/, draft(kickoff: "2026-10-06T00:15Z").text)   # Monday 8:15pm ET
    assert_match(/ #tnf\z/, draft(kickoff: "2026-10-02T00:15Z").text)   # Thursday 8:15pm ET
    assert_no_match(/#(snf|mnf|tnf)/, draft(kickoff: "2026-10-04T20:25Z").text) # Sunday 4:25pm ET
  end

  test "eastern time follows daylight saving on both sides of each switch" do
    assert_equal 20, X::PostDraft.eastern(Time.utc(2026, 10, 5, 0, 20)).hour   # EDT, UTC-4
    assert_equal 20, X::PostDraft.eastern(Time.utc(2026, 12, 7, 1, 15)).hour   # EST, UTC-5
    assert_equal 1,  X::PostDraft.eastern(Time.utc(2026, 11, 1, 5, 30)).hour   # last half hour of EDT
    assert_equal 1,  X::PostDraft.eastern(Time.utc(2026, 11, 1, 6, 30)).hour   # first half hour of EST
    assert_equal 3,  X::PostDraft.eastern(Time.utc(2026, 3, 8, 7, 0)).hour     # 2am EST springs to 3am EDT
  end

  test "a most recent final that was a LOSS is flagged, because the input said the team won" do
    result = draft(record: "3-1", won: false)

    assert_equal 1, result.exceptions.size
    assert_includes result.exceptions.first, "is a LOSS (KC @ LV, 30-27)"
    assert_match(/\AChiefs 3-1 /, result.text)
  end

  test "a final more than a week old is flagged as last week's game" do
    old    = [{ "date" => "2026-09-20T17:00Z", "shortName" => "KC @ DEN", "competitions" => [competition("12", true, 20, 17)] }]
    result = draft(events: old)

    assert(result.exceptions.any? { |x| x.include?("more than a week ago") })
  end

  test "a team with no slogan hashtag still drafts, and says so" do
    bills  = X::PostDraft::Team.new(name: "Kansas City Chiefs", location: "Kansas City", mascot: "Chiefs", hashtag: nil)
    result = draft(team: bills)

    assert_equal "Chiefs 4-0 #nfl #nflfootball #kansascity #chiefs", result.text
    assert_includes result.exceptions.first, "no slogan hashtag"
  end

  test "a mascot that starts with a digit keeps its tag, and a repeated tag is not doubled" do
    niners = X::PostDraft::Team.new(name: "San Francisco 49ers", location: "San Francisco", mascot: "49ers", hashtag: "#49ers")

    assert_equal "49ers 4-0 #nfl #nflfootball #49ers #sanfrancisco", draft(team: niners).text
  end

  test "refuses a team ESPN does not list, a missing record, and reports no finished game" do
    unknown = X::PostDraft::Team.new(name: "London Monarchs", location: "London", mascot: "Monarchs", hashtag: "#x")
    assert_includes assert_raises(X::PostDraft::Error) { draft(team: unknown) }.message, "no team named"
    assert_includes assert_raises(X::PostDraft::Error) { draft(record: "") }.message, "no record"
    assert_includes draft(events: []).exceptions.first, "no finished game"
  end
end
