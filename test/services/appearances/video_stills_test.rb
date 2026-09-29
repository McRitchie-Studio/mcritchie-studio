require "test_helper"
require Rails.root.join("db/seeds/data/night_call_looks.rb").to_s

# [unit] A music-video look is anchored on its clearest still, never a headshot,
# and refuses to build when no still can be signed.
class Appearances::VideoStillsTest < ActiveSupport::TestCase
  setup do
    @look = MusicVideos::CreateLook.call(NightCallLooks.seed!.video_performers.find_by!(ordinal: 2))
  end

  test "the anchor and the floor are the performer's stills, clearest first" do
    anchor = Content::ArtifactPlan::ModelInputs.new(@look).anchor

    assert anchor.reuse?
    assert_equal "Anchor still", anchor.label
    assert_match(/person_02_0042\.jpg\?/, anchor.url)
    assert_equal %w[0042 0306], Appearances::ReferenceImages.call(@look).map { |u| u[/0042|0306/] }
    assert_nil Content::ArtifactPlan::ModelInputs.new(@look).refusal_for(:sheet)
  end

  test "no reachable store means no anchor, so the sheet refuses before spending" do
    down = Object.new
    def down.signed_url(**) = raise(AssetBrowser::Unavailable, "down")

    AssetBrowser.stub(:source, down) do
      inputs = Content::ArtifactPlan::ModelInputs.new(@look)
      assert inputs.anchor.acquire?
      assert_match(/no reachable still/, inputs.refusal_for(:sheet))
    end
  end
end
