require "test_helper"
require Rails.root.join("bin/lib/game_model").to_s

# [unit] bin/game-model cannot boot Rails, so it carries a copy of the iced
# twin's wording. The copy must stay the app's: the same shades, the same
# generic pieces in the same order, and the same two special shots.
class GameModelIcedParityTest < ActiveSupport::TestCase
  PROMPT = Appearances::CharacterSheetPrompt

  test "the shades and the special shots are the app's" do
    assert_equal PROMPT::SHADES, GameModel::Prompts::SHADES
    assert_equal PROMPT::RINGS_VIEW, GameModel::Prompts::RINGS_VIEW
    assert_equal PROMPT::GRILL_VIEW, GameModel::Prompts::GRILL_VIEW
  end

  test "every generic piece is the app's, worded the same" do
    pieces = PROMPT::GENERIC_PIECES
    expected = ["chain: #{pieces['chain']}", "watch on his LEFT wrist: #{pieces['watch']}",
                "bracelet on his RIGHT wrist (the hand without the watch): #{pieces['bracelet']}",
                "grill: #{pieces['grill']}", "rings: #{pieces['rings']}"]
    assert_equal expected, GameModel::Prompts::ICED_PIECES
  end

  test "the filing service stamps the model the CLI pins, under the CLI's key folder" do
    assert_equal GameModel::MODEL, Appearances::FileGameLook::MODEL
    assert_equal GameModel::KEY_PREFIX, Appearances::FileGameLook::KEY_PREFIX
    assert_match Appearances::FileGameLook::KEY_SHAPE, GameModel::Filing.key("4431611", "Bears white · 2026 Week 6 at ATL", "iced")
  end
end
