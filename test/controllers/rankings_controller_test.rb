require "test_helper"

class RankingsControllerTest < ActionDispatch::IntegrationTest
  test "quarterback rankings page loads" do
    get nfl_quarterback_rankings_path
    assert_response :success
    assert_select "h1", /Quarterback Rankings/
  end

  test "quarterback rankings shows Josh Allen" do
    get nfl_quarterback_rankings_path
    assert_response :success
    assert_select "td", /Allen/
  end

  test "quarterback rankings sorts by passing" do
    get nfl_quarterback_rankings_path(sort: "passing")
    assert_response :success
  end

  test "quarterback rankings sorts by rushing" do
    get nfl_quarterback_rankings_path(sort: "rushing")
    assert_response :success
  end

  test "quarterback rankings supports search" do
    get nfl_quarterback_rankings_path(search: "allen")
    assert_response :success
    assert_select "td", /Allen/
  end

  test "quarterback rankings search with no results" do
    get nfl_quarterback_rankings_path(search: "zzzznonexistent")
    assert_response :success
    assert_select "p.text-muted", /No quarterback data/
  end

  test "offensive line rankings page loads" do
    get nfl_offensive_line_rankings_path
    assert_response :success
    assert_select "h1", /Offensive Line Rankings/
  end

  test "offensive line rankings shows OLine players" do
    get nfl_offensive_line_rankings_path
    assert_response :success
    assert_select "td", /Dawkins/
  end

  test "offensive line rankings sorts by run_block" do
    get nfl_offensive_line_rankings_path(sort: "run_block")
    assert_response :success
  end

  test "offensive line rankings sorts by offense" do
    get nfl_offensive_line_rankings_path(sort: "offense")
    assert_response :success
  end

  test "offensive line rankings supports search" do
    get nfl_offensive_line_rankings_path(search: "morse")
    assert_response :success
    assert_select "td", /Morse/
  end

  test "quarterback rankings redirects when no season" do
    Season.find_by(year: 2025, league: "nfl").destroy
    get nfl_quarterback_rankings_path
    assert_redirected_to root_path
  end

  test "offensive line rankings redirects when no season" do
    Season.find_by(year: 2025, league: "nfl").destroy
    get nfl_offensive_line_rankings_path
    assert_redirected_to root_path
  end

  # --- Receiving rankings ---

  test "receiving rankings page loads" do
    get nfl_receiving_rankings_path
    assert_response :success
    assert_select "h1", /Receiving Rankings/
  end

  test "receiving rankings shows WR players" do
    get nfl_receiving_rankings_path
    assert_response :success
    assert_select "td", /Shakir/
  end

  test "receiving rankings sorts by overall" do
    get nfl_receiving_rankings_path(sort: "overall")
    assert_response :success
  end

  test "receiving rankings supports search" do
    get nfl_receiving_rankings_path(search: "kincaid")
    assert_response :success
    assert_select "td", /Kincaid/
  end

  # --- Rushing rankings ---

  test "rushing rankings page loads" do
    get nfl_rushing_rankings_path
    assert_response :success
    assert_select "h1", /Rushing Rankings/
  end

  test "rushing rankings shows RB players" do
    get nfl_rushing_rankings_path
    assert_response :success
    assert_select "td", /Cook/
  end

  test "rushing rankings sorts by overall" do
    get nfl_rushing_rankings_path(sort: "overall")
    assert_response :success
  end

  # --- Defense rankings ---

  test "defense rankings page loads" do
    get nfl_defense_rankings_path
    assert_response :success
    assert_select "h1", /Defense Rankings/
  end

  test "defense rankings shows defensive players" do
    get nfl_defense_rankings_path
    assert_response :success
    assert_select "td", /Oliver/
  end

  test "defense rankings sorts by pass_rush" do
    get nfl_defense_rankings_path(sort: "pass_rush")
    assert_response :success
  end

  test "defense rankings sorts by coverage" do
    get nfl_defense_rankings_path(sort: "coverage")
    assert_response :success
  end

  test "defense rankings sorts by run_def" do
    get nfl_defense_rankings_path(sort: "run_def")
    assert_response :success
  end

  # --- Pass rush rankings ---

  test "pass rush rankings page loads" do
    get nfl_pass_rush_rankings_path
    assert_response :success
    assert_select "h1", /Pass Rush Rankings/
  end

  test "pass rush rankings shows edge rushers" do
    get nfl_pass_rush_rankings_path
    assert_response :success
    assert_select "td", /Miller/
  end

  test "pass rush rankings sorts by defense" do
    get nfl_pass_rush_rankings_path(sort: "defense")
    assert_response :success
  end

  # --- Coverage rankings ---

  test "coverage rankings page loads" do
    get nfl_coverage_rankings_path
    assert_response :success
    assert_select "h1", /Coverage Rankings/
  end

  test "coverage rankings shows DBs" do
    get nfl_coverage_rankings_path
    assert_response :success
    assert_select "td", /Douglas/
  end

  test "coverage rankings sorts by defense" do
    get nfl_coverage_rankings_path(sort: "defense")
    assert_response :success
  end

  # --- Coaches ---

  test "coaches page loads" do
    get nfl_coaches_path
    assert_response :success
    assert_select "h1", /NFL Coaches/
  end

  test "coaches page shows coach name" do
    get nfl_coaches_path
    assert_response :success
    assert_select "td", /McDermott/
  end

  test "coaches page sorts by role" do
    get nfl_coaches_path(sort: "role")
    assert_response :success
  end

  test "coaches page sorts by name" do
    get nfl_coaches_path(sort: "name")
    assert_response :success
  end

  test "coaches page supports search" do
    get nfl_coaches_path(search: "mcdermott")
    assert_response :success
    assert_select "td", /McDermott/
  end

  # --- Pass-first rankings ---

  test "pass-first rankings page loads" do
    get nfl_pass_first_rankings_path
    assert_response :success
    assert_select "h1", /Pass-First Rankings/
  end

  test "pass-first rankings shows coach name" do
    get nfl_pass_first_rankings_path
    assert_response :success
    assert_select "td", /McDermott/
  end

  test "pass-first rankings sorts by pass_heavy" do
    get nfl_pass_first_rankings_path(sort: "pass_heavy")
    assert_response :success
    assert_select "h2", /Pass-Heavy Rankings/
  end

  test "pass-first rankings supports search" do
    get nfl_pass_first_rankings_path(search: "mcdermott")
    assert_response :success
    assert_select "td", /McDermott/
  end

  test "pass-first rankings redirects when no season" do
    Season.find_by(year: 2025, league: "nfl").destroy
    get nfl_pass_first_rankings_path
    assert_redirected_to root_path
  end

  # --- Prospects ---

  test "prospects page loads" do
    get nfl_prospects_path
    assert_response :success
    assert_select "h1", /2025 NFL Draft Prospects/
  end

  test "prospects page shows Cam Ward" do
    get nfl_prospects_path
    assert_response :success
    assert_select "td", /Ward/
  end

  test "prospects page sorts by grade" do
    get nfl_prospects_path(sort: "grade")
    assert_response :success
  end

  test "prospects page sorts by position" do
    get nfl_prospects_path(sort: "position")
    assert_response :success
  end

  test "prospects page supports search" do
    get nfl_prospects_path(search: "ward")
    assert_response :success
    assert_select "td", /Ward/
  end

  test "prospects page search with no results" do
    get nfl_prospects_path(search: "zzzznonexistent")
    assert_response :success
    assert_select "p.text-muted", /No prospect data/
  end

  test "prospects page redirects when no season" do
    Season.find_by(year: 2025, league: "nfl").destroy
    get nfl_prospects_path
    assert_redirected_to root_path
  end

  test "prospects page shows grade ranges" do
    get nfl_prospects_path
    assert_response :success
  end

  # --- Prospects 2026 ---

  test "prospects 2026 page loads" do
    get nfl_prospects_path(year: 2026)
    assert_response :success
    assert_select "h1", /2026 NFL Draft Prospects/
  end

  test "prospects 2026 shows mock draft prospects" do
    get nfl_prospects_path(year: 2026)
    assert_response :success
    assert_select "td", /Bailey/
  end

  test "prospects 2026 sort by grade" do
    get nfl_prospects_path(year: 2026, sort: "grade")
    assert_response :success
  end

  test "prospects defaults to 2025 with invalid year" do
    get nfl_prospects_path(year: 9999)
    assert_response :success
    assert_select "h1", /2025 NFL Draft Prospects/
  end

  # --- Team unit rankings ---

  test "team unit rankings page loads" do
    get nfl_team_rankings_path("buffalo-bills")
    assert_response :success
    assert_select "h1", /Buffalo Bills/
  end

  test "team unit rankings shows rank data" do
    get nfl_team_rankings_path("buffalo-bills")
    assert_response :success
    assert_select "span", /3/  # QB rank
  end

  test "team unit rankings shows offense and defense sections" do
    get nfl_team_rankings_path("buffalo-bills")
    assert_response :success
    assert_select "h2", /Offense/
    assert_select "h2", /Defense/
  end

  test "team unit rankings shows team selector" do
    get nfl_team_rankings_path("buffalo-bills")
    assert_response :success
    assert_select "a[href=?]", nfl_team_rankings_path("miami-dolphins")
  end

  test "team unit rankings redirects for missing team" do
    get nfl_team_rankings_path("nonexistent-team")
    assert_redirected_to nfl_hub_path
  end

  test "team unit rankings redirects when no season" do
    Season.find_by(year: 2025, league: "nfl").destroy
    get nfl_team_rankings_path("buffalo-bills")
    assert_redirected_to root_path
  end

  # --- Player impact ---

  test "player impact page loads" do
    get nfl_player_impact_path(player_id: "david-bailey", team_id: "buffalo-bills")
    assert_response :success
    assert_select "h1", /David Bailey/
    assert_select "h1", /Buffalo Bills/
  end

  test "player impact with missing player redirects" do
    get nfl_player_impact_path(player_id: "nonexistent-player", team_id: "buffalo-bills")
    assert_redirected_to nfl_hub_path
    assert_equal "Player not found", flash[:alert]
  end

  test "player impact with missing team redirects" do
    get nfl_player_impact_path(player_id: "david-bailey", team_id: "nonexistent-team")
    assert_redirected_to nfl_hub_path
    assert_equal "Team not found", flash[:alert]
  end

  test "player impact redirects when no season" do
    Season.find_by(year: 2025, league: "nfl").destroy
    get nfl_player_impact_path(player_id: "david-bailey", team_id: "buffalo-bills")
    assert_redirected_to nfl_hub_path
  end

  test "player impact shows affected rankings section" do
    get nfl_player_impact_path(player_id: "david-bailey", team_id: "buffalo-bills")
    assert_response :success
    assert_select "h2", /Affected Rankings/
  end

  # --- Confirm draft pick ---

  test "confirm draft pick requires admin" do
    post confirm_draft_pick_path(player_id: "david-bailey", team_id: "buffalo-bills")
    assert_redirected_to login_path

    log_in_as(users(:viewer))
    post confirm_draft_pick_path(player_id: "david-bailey", team_id: "buffalo-bills")
    assert_redirected_to root_path
  end

  test "confirm draft pick creates contract and news" do
    log_in_as(users(:alex))
    # Remove existing mock_pick so we test fresh creation
    Contract.find_by(person_slug: "david-bailey", team_slug: "buffalo-bills")&.destroy

    assert_difference "News.count", 1 do
      post confirm_draft_pick_path(player_id: "david-bailey", team_id: "buffalo-bills")
    end

    contract = Contract.find_by(person_slug: "david-bailey", team_slug: "buffalo-bills")
    assert_not_nil contract
    assert_equal "draft_pick", contract.contract_type
    assert_equal "EDGE", contract.position

    news = News.last
    assert_equal "refined", news.stage
    assert_match(/David Bailey/, news.title)
    assert_match(/drafted/, news.title)
    assert_not_nil news.refined_at

    assert_redirected_to nfl_player_impact_path(player_id: "david-bailey", team_id: "buffalo-bills")
  end

  test "confirm draft pick converts mock_pick to draft_pick" do
    log_in_as(users(:alex))
    mock = contracts(:bailey_mock)
    assert_equal "mock_pick", mock.contract_type

    assert_no_difference "Contract.count" do
      post confirm_draft_pick_path(player_id: "david-bailey", team_id: "buffalo-bills")
    end

    mock.reload
    assert_equal "draft_pick", mock.contract_type
  end

  test "confirm draft pick with bench_rookie skips ranking recompute" do
    log_in_as(users(:alex))
    Contract.find_by(person_slug: "david-bailey", team_slug: "buffalo-bills")&.destroy

    # Get current ranking state
    rankings_before = TeamRanking.where(season_slug: "nfl-2025", week: nil).pluck(:team_slug, :rank_type, :rank)

    post confirm_draft_pick_path(player_id: "david-bailey", team_id: "buffalo-bills"),
         params: { bench_rookie: "1" }

    rankings_after = TeamRanking.where(season_slug: "nfl-2025", week: nil).pluck(:team_slug, :rank_type, :rank)
    assert_equal rankings_before, rankings_after
  end

  test "confirm draft pick rejects already confirmed" do
    log_in_as(users(:alex))
    # Cam Ward already has a draft_pick contract to Buffalo Bills
    post confirm_draft_pick_path(player_id: "cam-ward", team_id: "buffalo-bills")
    assert_redirected_to nfl_player_impact_path(player_id: "cam-ward", team_id: "buffalo-bills")
    assert_match(/already confirmed/, flash[:notice])
  end

  test "confirm draft pick expires college contracts" do
    log_in_as(users(:alex))
    college = contracts(:bailey_college)
    assert_nil college.expires_at

    post confirm_draft_pick_path(player_id: "david-bailey", team_id: "buffalo-bills")

    college.reload
    assert_equal Date.current, college.expires_at
  end

  test "confirm draft pick with missing player redirects" do
    log_in_as(users(:alex))
    post confirm_draft_pick_path(player_id: "nonexistent-player", team_id: "buffalo-bills")
    assert_redirected_to nfl_hub_path
  end

  test "confirm draft pick with missing team redirects" do
    log_in_as(users(:alex))
    post confirm_draft_pick_path(player_id: "david-bailey", team_id: "nonexistent-team")
    assert_redirected_to nfl_hub_path
  end
end
