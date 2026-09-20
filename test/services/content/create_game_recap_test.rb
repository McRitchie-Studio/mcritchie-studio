require "test_helper"

class Content
  class CreateGameRecapTest < ActiveSupport::TestCase
    # buffalo_bills (Bills) and miami_dolphins (Dolphins) are the only two NFL
    # teams in the fixtures, and both carry an explicit `mascot`.
    setup do
      @bills = teams(:buffalo_bills)
      @fins  = teams(:miami_dolphins)
    end

    def payload(**overrides)
      {
        game_slug:      "buffalo-bills-vs-miami-dolphins",
        home_team_slug: @bills.slug,
        away_team_slug: @fins.slug,
        home_score:     24,
        away_score:     17,
        status_detail:  "Final",
        season_year:    2026,
        season_type:    2,
        week:           3
      }.merge(overrides)
    end

    test "home win reads as winner beat loser with the score" do
      result = Content::CreateGameRecap.new(payload).call

      assert result.created?
      assert_equal "Bills Beat Dolphins 24-17", result.content.title
    end

    test "away win names the away team as the winner" do
      result = Content::CreateGameRecap.new(payload(home_score: 13, away_score: 31)).call

      assert_equal "Dolphins Beat Bills 31-13", result.content.title
    end

    # The score is always winner-first, never home-first. An away win that
    # printed "31-13" from the home column would read as a Bills blowout.
    test "score is ordered winner first regardless of home or away" do
      result = Content::CreateGameRecap.new(payload(home_score: 3, away_score: 45)).call

      assert_equal "Dolphins Beat Bills 45-3", result.content.title
    end

    test "a tie says tie rather than beat" do
      result = Content::CreateGameRecap.new(payload(home_score: 17, away_score: 17)).call

      assert_equal "Bills And Dolphins Tie 17-17", result.content.title
      assert result.content.game_facts["tie"]
      assert_nil result.content.game_facts["winner_slug"]
    end

    test "winner lands on team_slug and loser on rival_team_slug" do
      content = Content::CreateGameRecap.new(payload(home_score: 10, away_score: 20)).call.content

      assert_equal @fins.slug,  content.team_slug
      assert_equal @bills.slug, content.rival_team_slug
      assert_equal @fins.slug,  content.winning_team.slug
      assert_equal @bills.slug, content.losing_team.slug
    end

    test "creates at stage idea on the game_recap workflow" do
      content = Content::CreateGameRecap.new(payload).call.content

      assert_equal "idea",       content.stage
      assert_equal "game_recap", content.workflow
      assert_equal "game",       content.source_type
      assert content.game_recap?
    end

    test "records the scoreline in game_facts" do
      facts = Content::CreateGameRecap.new(payload).call.content.game_facts

      assert_equal 24, facts["home_score"]
      assert_equal 17, facts["away_score"]
      assert_equal @bills.slug, facts["winner_slug"]
      assert_equal @fins.slug,  facts["loser_slug"]
      assert_equal "Final", facts["status_detail"]
      assert_equal 3, facts["week"]
    end

    # The poll cycle re-runs by design, so the same final arrives repeatedly.
    test "a repeated final returns the existing recap without creating a second" do
      first = Content::CreateGameRecap.new(payload).call
      assert first.created?

      second = nil
      assert_no_difference -> { Content.count } do
        second = Content::CreateGameRecap.new(payload).call
      end

      assert_not second.created?
      assert_equal first.content.id, second.content.id
    end

    # A re-poll after a correction must not quietly fork a second recap.
    test "a repeated final with a changed score still does not create a second" do
      first = Content::CreateGameRecap.new(payload).call

      assert_no_difference -> { Content.count } do
        second = Content::CreateGameRecap.new(payload(home_score: 27)).call
        assert_equal first.content.id, second.content.id
      end
    end

    test "the database refuses a second recap for the same game" do
      Content::CreateGameRecap.new(payload).call

      assert_raises ActiveRecord::RecordNotUnique do
        Content.create!(
          title: "duplicate", workflow: "game_recap",
          game_slug: "buffalo-bills-vs-miami-dolphins", stage: "idea"
        )
      end
    end

    test "rejects a team the hub does not know" do
      error = assert_raises Content::CreateGameRecap::InvalidGame do
        Content::CreateGameRecap.new(payload(away_team_slug: "nonexistent-team")).call
      end

      assert_match "nonexistent-team", error.message
    end

    test "rejects a missing required field" do
      assert_raises Content::CreateGameRecap::InvalidGame do
        Content::CreateGameRecap.new(payload(game_slug: nil)).call
      end
    end

    # `"final".to_i` is 0, which would invent a 0-0 shutout rather than fail.
    test "rejects a score that is not a whole number" do
      assert_raises Content::CreateGameRecap::InvalidGame do
        Content::CreateGameRecap.new(payload(home_score: "final")).call
      end
    end

    test "rejects a negative score" do
      assert_raises Content::CreateGameRecap::InvalidGame do
        Content::CreateGameRecap.new(payload(away_score: -3)).call
      end
    end

    test "rejects a game played against itself" do
      assert_raises Content::CreateGameRecap::InvalidGame do
        Content::CreateGameRecap.new(payload(away_team_slug: @bills.slug)).call
      end
    end

    # Scores arrive over JSON, so a numeric string is the normal shape.
    test "accepts scores that arrive as numeric strings" do
      result = Content::CreateGameRecap.new(payload(home_score: "24", away_score: "17")).call

      assert_equal "Bills Beat Dolphins 24-17", result.content.title
      assert_equal 24, result.content.game_facts["home_score"]
    end

    test "accepts a string-keyed payload" do
      result = Content::CreateGameRecap.new(payload.transform_keys(&:to_s)).call

      assert result.created?
      assert_equal "Bills Beat Dolphins 24-17", result.content.title
    end
  end
end
