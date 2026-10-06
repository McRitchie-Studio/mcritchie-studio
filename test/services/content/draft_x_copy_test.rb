require "test_helper"

# [unit] Content::DraftXCopy — the card's half of the draft: what lands on the
# record, and that a draft which cannot be read does not lose the card.
class Content::DraftXCopyTest < ActiveSupport::TestCase
  # The Bills won at 17:00Z on the latest day that carries no prime-time tag
  # (#mnf, #tnf), so the caption reads the same any day.
  FETCH = lambda do |url|
    kickoff = 1.day.ago.utc
    kickoff -= 1.day while kickoff.monday? || kickoff.thursday?
    case url
    when %r{/teams\z}     then { "sports" => [{ "leagues" => [{ "teams" => [{ "team" => { "id" => "2", "displayName" => "Buffalo Bills" } }] }] }] }
    when %r{/teams/2\z}   then { "team" => { "record" => { "items" => [{ "summary" => "3-1" }] } } }
    when %r{/schedule\z}
      { "events" => [{ "date" => kickoff.strftime("%Y-%m-%dT17:00Z"), "shortName" => "NE @ BUF",
                       "competitions" => [{ "status" => { "type" => { "completed" => true } }, "competitors" => [
                         { "winner" => true, "score" => { "displayValue" => "27" }, "team" => { "id" => "2" } },
                         { "winner" => false, "score" => { "displayValue" => "20" }, "team" => { "id" => "17", "displayName" => "New England Patriots" } }
                       ] }] }] }
    end
  end

  setup do
    teams(:buffalo_bills).update!(hashtag: "#BillsMafia")
    @content = Content.create!(title: "Bills win", workflow: "video_post_x", team_slug: "buffalo-bills",
                               final_video_url: "https://cdn.test/v.mp4")
    Content::DraftXCopy.fetch = FETCH
  end

  teardown { Content::DraftXCopy.fetch = nil }

  test "saves the copy and the facts, and moves the card to ready" do
    Content::DraftXCopy.new(@content).call
    @content.reload

    assert_equal "Bills 3-1 #nfl #nflfootball #billsmafia #buffalo #bills", @content.captions
    assert_equal "script", @content.stage
    assert_equal "3-1", @content.game_facts["record"]
    assert_equal [], @content.game_facts["exceptions"]
  end

  test "a draft that cannot be read keeps the card at idea with the reason" do
    Content::DraftXCopy.fetch = ->(_url) { raise X::PostDraft::Error, "could not read ESPN" }
    Content::DraftXCopy.new(@content).call
    @content.reload

    assert_equal "idea", @content.stage
    assert_nil @content.captions
    assert_equal "could not read ESPN", @content.game_facts["draft_error"]
  end

  test "refuses a card with no team, another workflow, and one already in flight" do
    @content.update_columns(team_slug: nil)
    assert_includes assert_raises(Content::DraftXCopy::Refused) { Content::DraftXCopy.new(@content).call }.message, "pick the team"

    recap = Content.create!(title: "Recap", workflow: "game_recap")
    assert_raises(Content::DraftXCopy::Refused) { Content::DraftXCopy.new(recap).call }

    @content.update_columns(team_slug: "buffalo-bills", stage: "assembly")
    assert_includes assert_raises(Content::DraftXCopy::Refused) { Content::DraftXCopy.new(@content).call }.message, "past its draft"
  end
end
