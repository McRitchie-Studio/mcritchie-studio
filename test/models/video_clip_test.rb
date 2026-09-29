# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/seeds/data/night_call_clips.rb").to_s

# [unit] A clip is 24-26 s, its seam falls inside it, its people are the
# video's, and its R2 key spells out exactly this window.
class VideoClipTest < ActiveSupport::TestCase
  setup do
    @video = NightCallClips.seed!
    @clip = @video.video_clips.first
  end

  test "the seeded clip is valid and its prompt targets its performer" do
    assert @clip.valid?, @clip.errors.full_messages.to_sentence
    assert_equal 1, @clip.target.ordinal
    assert_match "Replace the person in the desk scenes", @clip.prompt
  end

  test "clips run 24 to 26 seconds" do
    @clip.end_ms = @clip.start_ms + 23_999
    assert_not @clip.valid?
    assert_match "clips run 24 to 26 s", @clip.errors[:end_ms].first
  end

  test "the seam must fall inside the window" do
    @clip.seam_ms = @clip.end_ms
    assert_not @clip.valid?
    assert @clip.errors.key?(:seam_ms)
  end

  test "people must be the video's own performers" do
    @clip.target_performer = 9
    assert_not @clip.valid?
    assert_match "no such person: 9", @clip.errors[:performer_ordinals].first
  end

  test "the object key must name this window in the video's folder" do
    @clip.object_key = @clip.object_key.sub("0017_0042", "0018_0042")
    assert_not @clip.valid?
    assert_match "night_call_clips_clip_01_chorus_to_verse_solo_plus_background_0017_0042.mp4", @clip.errors[:object_key].first
  end

  test "an unknown seam or shape is refused" do
    @clip.seam = "bridge"
    @clip.cast_shape = "quartet"
    assert_not @clip.valid?
    assert @clip.errors.key?(:seam)
    assert @clip.errors.key?(:cast_shape)
  end

  test "the stage follows approvals: clips_ready with one, back when none" do
    assert_equal "cast_confirmed", @video.stage
    @clip.update!(status: "approved")
    @video.sync_clip_stage!
    assert_equal "clips_ready", @video.reload.stage
    assert @video.cast_confirmed?, "a clips_ready video's cast is still confirmed"

    @clip.update!(status: "rejected")
    @video.sync_clip_stage!
    assert_equal "cast_confirmed", @video.reload.stage
  end
end
