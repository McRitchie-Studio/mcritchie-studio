require "test_helper"
require_relative "../../support/tiktok_draft_fakes"

# [unit] Tiktok::ClipCaption — a team in, the TikTok caption out, written by
# code the same way every time. Shares X's record read and tag spelling, but
# carries its own hashtag set, bounded in count and in TikTok's 2,200
# characters. Every ESPN read is a fake.
class Tiktok::ClipCaptionTest < ActiveSupport::TestCase
  BILLS = X::PostDraft::Team.new(name: "Buffalo Bills", location: "Buffalo", mascot: "Bills", hashtag: "#BillsMafia")
  NOW = Time.utc(2026, 10, 7, 12, 0)

  def caption(team: BILLS, league: "nfl", **espn)
    Tiktok::ClipCaption.new(team:, league:, fetch: TiktokDraftFakes.espn(names: ["Buffalo Bills"], **espn), now: NOW).call
  end

  test "writes the mascot, the record ESPN reports and TikTok's tags" do
    result = caption

    assert_equal "Bills 3-2 #nfl #nfltiktok #footballtiktok #billsmafia #bills #fyp", result.text
    assert_empty result.exceptions
    assert_equal "3-2", result.facts["record"]
    assert_equal "SYN @ HOME", result.facts.dig("last_final", "matchup")
    assert_includes result.facts["source"], "site.web.api.espn.com"
    assert_equal "2026-10-07T12:00:00Z", result.facts["read_at"]
  end

  test "the same input writes the same caption every time" do
    assert_equal caption.text, caption.text
  end

  test "its hashtag set is TikTok's own, not X's" do
    tiktok = Tiktok::ClipCaption.hashtags(BILLS)
    x = X::PostDraft.new(team: BILLS, fetch: TiktokDraftFakes.espn(names: ["Buffalo Bills"]), now: NOW).call.text.scan(/#\w+/)

    refute_equal x, tiktok
    assert_includes tiktok, "#nfltiktok"
    assert_includes tiktok, "#fyp"
    refute_includes tiktok, "#nflfootball", "X's second league tag is not in TikTok's set"
    refute_includes tiktok, "#buffalo", "TikTok's set carries no city tag"
    # Shared, not copied: the team's slogan and mascot tags are spelled by X::PostDraft.tag.
    assert_includes tiktok, X::PostDraft.tag(BILLS.mascot)
  end

  test "a tag is never repeated and the set never passes its bound" do
    echo = BILLS.dup.tap { |t| t.hashtag = "#Bills" } # the slogan tag equals the mascot tag
    tags = Tiktok::ClipCaption.hashtags(echo)

    assert_equal tags.uniq, tags
    assert_equal ["#nfl", "#nfltiktok", "#footballtiktok", "#bills", "#fyp"], tags
    assert_operator Tiktok::ClipCaption.hashtags(BILLS).size, :<=, Tiktok::ClipCaption::MAX_HASHTAGS
  end

  test "the caption is bounded by TikTok's 2,200 characters, counted as TikTok counts" do
    assert_operator Tiktok::ClipCaption.length(caption.text), :<=, Tiktok::ClipCaption::MAX_CHARS
    assert_equal 2, Tiktok::ClipCaption.length("🏈"), "an emoji is two UTF-16 units"
    assert_equal 2_200, Tiktok::ClipCaption::MAX_CHARS
  end

  test "a caption over the limit is refused, not cut" do
    huge = BILLS.dup.tap { |t| t.mascot = "B" * 2_200 }

    error = assert_raises(Tiktok::ClipCaption::Error) { caption(team: huge) }
    assert_match(/over TikTok's 2200/, error.message)
  end

  test "a missing slogan, or no finished game, is a CHECK, not a refusal" do
    plain = BILLS.dup.tap { |t| t.hashtag = nil }

    assert_equal "Bills 3-2 #nfl #nfltiktok #footballtiktok #bills #fyp", caption(team: plain).text
    assert_includes caption(team: plain).exceptions, "Buffalo Bills has no slogan hashtag on file"
    assert_includes caption(finished: false).exceptions, "ESPN shows no finished game for Buffalo Bills this season"
  end

  test "a team outside the NFL is refused: its record cannot be read" do
    error = assert_raises(Tiktok::ClipCaption::Error) { caption(league: "ncaa") }
    assert_match(/NCAA team; only an NFL team's record can be read/, error.message)
  end

  test "a record ESPN cannot give is refused, never recalled" do
    error = assert_raises(Tiktok::ClipCaption::Error) { caption(record: "") }
    assert_match(/no record for Buffalo Bills/, error.message)
  end
end
