# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/tiled_video.rb").to_s

# [unit] An alt video clip's slug (recast pipeline, piece 19): the readable
# name the operator hands to the tiktok-draft SOP. Assigned when Build Clips
# makes the clip, "<alt video slug>-clip-<NN>", and unique. Wholly synthetic.
class AltVideoClipSlugTest < ActiveSupport::TestCase
  setup do
    @video = TiledVideo.seed!
    @alt = AltVideo.build_from!(@video)
  end

  test "Build Clips names every clip after its alt video and ordinal, two digits" do
    assert_equal %w[test-artist-a-tiled-demo-alt-1-clip-01 test-artist-a-tiled-demo-alt-1-clip-02
                    test-artist-a-tiled-demo-alt-1-clip-03 test-artist-a-tiled-demo-alt-1-clip-04],
                 @alt.clips.map(&:slug)
    assert_equal "bigxthaplug-6wa-alt-3-clip-03", AltVideoClip.slug_for("bigxthaplug-6wa-alt-3", 3)
    assert_equal "x-alt-1-clip-12", AltVideoClip.slug_for("x-alt-1", 12)
  end

  test "a second alt video's clips never share a slug with the first's" do
    second = AltVideo.build_from!(@video.reload)

    assert_equal "test-artist-a-tiled-demo-alt-2-clip-01", second.clips.first.slug
    assert_equal AltVideoClip.count, AltVideoClip.distinct.count(:slug)
  end

  test "the slug is stable: it cannot be renamed away from its rule" do
    clip = @alt.clips.first
    clip.slug = "something-else"

    refute clip.valid?
    assert_includes clip.errors[:slug], "must be test-artist-a-tiled-demo-alt-1-clip-01"
  end

  test "a clip is found by its slug" do
    assert_equal @alt.clips.third, AltVideoClip.find_by!(slug: "test-artist-a-tiled-demo-alt-1-clip-03")
  end
end
