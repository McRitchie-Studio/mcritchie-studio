require_relative "tiled_video"

# A 72 s cinematic video for the recast picker: two people, both kept as is (a
# cinematic card closes without an artist), the cast confirmed, four chunks
# tiled, and one athlete with two looks to recast them into. For the recast
# tests, the e2e and the local demo. Wholly synthetic: a made-up video, visible
# cue labels, a made-up athlete. The operator, never the agent, names who is
# on screen and who replaces them.
module RecastVideo
  SLUG = "test-cinematic-recast-demo".freeze
  SOURCE = "music_videos/test_cinematic/recast_demo/source/test_cinematic_recast_demo.mp4".freeze
  DURATION_MS = TiledVideo::DURATION_MS
  ATHLETE = { first_name: "Test", last_name: "Athlete Alpha" }.freeze
  LOOKS = ["Home Blue", "Away White"].freeze

  def self.athlete!
    person = Person.find_by(ATHLETE) || Person.create!(athlete: true, **ATHLETE)
    LOOKS.each { |descriptor| person.appearances.live.find_or_create_by!(descriptor:) }
    person
  end

  def self.video!
    video = MusicVideo.find_or_create_by!(slug: SLUG) do |v|
      v.kind = "cinematic"
      v.platform = "youtube"
      v.source_url = "https://www.youtube.com/watch?v=recast-demo"
      v.source_id = "recast-demo"
      v.title = "Test Cinematic - Recast Demo"
      v.duration_ms = DURATION_MS
      v.source_object_key = SOURCE
    end
    return video if video.video_performers.exists?

    MusicVideos::ReplacePerformers.new(video, TiledVideo::PERFORMERS).call
    video.video_performers.each { |p| p.update!(recast_keep: true) }
    video.confirm_cast!
    video
  end

  # The rows bin/find-clips --tile would post. No performer is labelled with an
  # artist, so no chunk has a labelled target: the recast picks the prompt's.
  def self.chunk_rows(video = video!)
    cast = video.video_performers.map { |p| p.as_json(only: %w[ordinal artist_slug extra sightings]) }
    MusicVideos::ChunkTiler.windows(DURATION_MS).map do |w|
      seen = MusicVideos::ClipCast.label(cast, w.start_ms, w.end_ms)
      { "ordinal" => w.ordinal, "start_ms" => w.start_ms, "end_ms" => w.end_ms, "cast_shape" => seen.cast_shape,
        "target_performer" => seen.target, "performer_ordinals" => seen.present,
        "object_key" => MusicVideos::ObjectKeys.chunk(source_key: SOURCE, ordinal: w.ordinal, start_ms: w.start_ms, end_ms: w.end_ms) }
    end
  end

  def self.seed!
    athlete!
    video = video!
    MusicVideos::ReplaceClips.new(video, chunk_rows(video), kind: "chunk").call unless video.video_chunks.exists?
    video
  end
end
