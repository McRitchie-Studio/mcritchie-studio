require "test_helper"

class MusicVideoTest < ActiveSupport::TestCase
  def video(**attrs)
    MusicVideo.new({ slug: "steve-aoki-night-call", platform: "youtube", source_url: "https://youtu.be/x",
                     source_id: "x", title: "Night Call",
                     source_object_key: "music_videos/steve_aoki/night_call/source/a.mp4" }.merge(attrs))
  end

  test "defaults to kind music_video, stage digested and empty timing" do
    v = video
    assert v.valid?, v.errors.full_messages.inspect
    assert_equal ["music_video", "digested", { "cues" => [], "sections" => [] }], [v.kind, v.stage, v.caption_timing]
  end

  test "slug is kebab-case and the key sits under music_videos/" do
    assert_not video(slug: "Steve_Aoki").valid?
    assert_not video(source_object_key: "elsewhere/a.mp4").valid?
  end

  test "caption timing holds only integers and a closed section vocabulary" do
    assert video(caption_timing: { "cues" => [{ "start_ms" => 1, "end_ms" => 2 }],
                                   "sections" => [{ "kind" => "instrumental", "start_ms" => 1, "end_ms" => 2 }] }).valid?
    assert_not video(caption_timing: { "cues" => [{ "start_ms" => "one", "end_ms" => 2 }], "sections" => [] }).valid?
    assert_not video(caption_timing: { "cues" => [{ "start_ms" => 1, "end_ms" => 2, "text" => "la" }], "sections" => [] }).valid?
    assert_not video(caption_timing: { "cues" => [], "sections" => [], "lines" => ["la"] }).valid?
    assert_not video(caption_timing: ["la"]).valid?
  end
end
