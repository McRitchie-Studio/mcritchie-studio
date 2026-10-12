require "test_helper"

class VideoTest < ActiveSupport::TestCase
  def video(**attrs)
    Video.new({ slug: "steve-aoki-night-call", platform: "youtube", source_url: "https://youtu.be/x",
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

  test "[unit] a video is a music video, a cinematic video or a movie scene, and the badge names each" do
    assert_equal %w[music_video cinematic movie_scene], Video::KINDS
    { "music_video" => "Music video", "cinematic" => "Cinematic", "movie_scene" => "Movie scene" }.each do |kind, label|
      v = video(kind:)
      assert v.valid?, "#{kind}: #{v.errors.full_messages.inspect}"
      assert_equal label, v.kind_label
    end
    assert_not video(kind: "documentary").valid?
    assert_not video(kind: "music video").valid?, "the stored value is snake_case"
  end

  test "[unit] a movie scene keeps its source under the same music_videos/ prefix" do
    assert video(kind: "movie_scene", source_object_key: "music_videos/test_studio/test_scene/source/a.mp4").valid?
    assert_not video(kind: "movie_scene", source_object_key: "videos/test_studio/test_scene/source/a.mp4").valid?
  end

  test "[unit] the table is videos and every child points at it by video_slug" do
    assert_equal "videos", Video.table_name
    assert_equal "video_artists", VideoArtist.table_name
    %i[video_artists video_performers video_clips alt_videos looks].each do |name|
      reflection = Video.reflect_on_association(name)
      assert_equal "video_slug", reflection.foreign_key.to_s, name
      assert_equal :video, reflection.inverse_of&.name, name
    end
    [AltVideo, Appearance, VideoArtist, VideoClip, VideoPerformer, VideoStitch].each do |model|
      assert_equal Video, model.reflect_on_association(:video).klass, model.name
      assert_includes model.column_names, "video_slug", model.name
      assert_not_includes model.column_names, "music_video_slug", model.name
    end
    assert_includes Video.connection.columns("video_chunk_takes").map(&:name), "video_slug", "the takes table has no model"
  end

  test "[unit] the old names still resolve, for anything serialized before the rename" do
    assert_same Video, MusicVideo
    assert_same Videos, MusicVideos
    assert_same Videos::RunStitch, MusicVideos::RunStitch
    assert_same Videos::ObjectKeys, "MusicVideos::ObjectKeys".constantize
    assert_equal "Video", MusicVideo.name, "a record built through the alias is written as Video"
    assert_equal "Video", MusicVideo.polymorphic_name
  end

  test "[integration] a record created under the old constant is a Video row, found by its GlobalID either way" do
    v = video(slug: "test-artist-a-alias-demo", source_id: "alias")
    v.save!
    assert_equal v, GlobalID::Locator.locate("gid://#{GlobalID.app}/MusicVideo/#{v.id}")
    assert_equal v, GlobalID::Locator.locate(v.to_global_id)
    assert_equal "gid://#{GlobalID.app}/Video/#{v.id}", v.to_global_id.to_s
  end
end
