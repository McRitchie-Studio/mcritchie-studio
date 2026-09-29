# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_looks.rb").to_s

# [component] One look card: its reference stills clearest first (or "not
# reachable"), its sheet or the empty state, and the cost hint by the button.
class MusicVideoLookCardTest < ActionView::TestCase
  setup do
    ImageGeneration::Registry.reload!
    @video = NightCallLooks.seed!
    @look = MusicVideos::CreateLook.call(@video.video_performers.find_by!(ordinal: 2))
    @keys = @look.video_performer.reference_still_keys
    @row = ImageGeneration::Registry.find!("openai_gpt5_sheet")
  end

  def render_card(sheet: nil, ready: true, still_urls: { @keys.first => "https://fixture.invalid/a.jpg?sig" })
    render partial: "music_videos/look",
           locals: { look: @look, video: @video, still_urls:, sheet:, sheet_row: @row, sheet_ready: ready }
  end

  test "references render clearest first, and a still with no URL says it is not reachable" do
    render_card

    assert_select "[data-test='look-reference']", 2
    assert_select "[data-test='look-reference']:first-child[data-visibility='clear'] img[src='https://fixture.invalid/a.jpg?sig']"
    assert_select "[data-test='look-reference']:last-child[data-visibility='partial']" do
      assert_select "img", 0
      assert_select "[data-test='still-unreachable']", /Still not reachable: person_02_0306\.jpg/
    end
  end

  test "no sheet shows the empty state, the build button and the cost hint" do
    render_card

    assert_select "[data-test='look-sheet-empty']", /No character sheet yet/
    assert_select "[data-test='build-sheet-form'] button", /Build character sheet/
    assert_select "[data-test='look-cost-hint']", /Costs money: one sheet per press.*6,724–7,629 tokens per sheet/m
  end

  test "a built sheet shows its image and the button offers a rebuild" do
    sheet = Artifact.create!(kind: "character_sheet", image_url: "https://example.com/sheet.png",
                             generator: @row.key, billable_units: 7_629)
    render_card(sheet:)

    assert_select "img[data-test='look-sheet-image'][src='https://example.com/sheet.png']"
    assert_select "[data-test='look-sheet-empty']", 0
    assert_select "[data-test='build-sheet-form'] button", /Rebuild character sheet/
  end

  test "an unconfigured generator hides the button and names the variable" do
    render_card(ready: false)

    assert_select "[data-test='build-sheet-form']", 0
    assert_select "[data-test='look-generator-off']", /OPENAI_API_KEY/
    assert_select "[data-test='look-cost-hint']"
  end
end
