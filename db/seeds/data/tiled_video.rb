# A 72 s cinematic video tiled into four overlapping chunks (0-25, 20-45, 40-65,
# 60-72) beside one seam candidate, for the chunk tests, the e2e and the local
# demo. Wholly synthetic: a made-up video, a made-up artist, visible-cue labels.
# The operator, never the agent, names who is on screen.
module TiledVideo
  SLUG = "test-artist-a-tiled-demo".freeze
  SOURCE = "music_videos/test_artist_a/tiled_demo/source/test_artist_a_tiled_demo.mp4".freeze
  DURATION_MS = 72_000
  ARTIST = "Test Artist A".freeze
  PERFORMERS = [
    { "ordinal" => 1, "label" => "man in the red jacket", "confidence_note" => "On screen throughout.",
      "sightings" => (3..69).step(3).map { |s| { "t_ms" => s * 1000, "visibility" => "clear" } }, "still_object_keys" => [] },
    { "ordinal" => 2, "label" => "woman in the doorway", "confidence_note" => "Background, first half only.",
      "sightings" => [9, 12, 30].map { |s| { "t_ms" => s * 1000, "visibility" => "partial" } }, "still_object_keys" => [] }
  ].freeze
  CANDIDATE = { ordinal: 1, start_ms: 30_000, end_ms: 55_000, seam: "section_change", seam_ms: 42_000,
                cast_shape: "solo_plus_background", target_performer: 1, performer_ordinals: [1, 2] }.freeze

  def self.video!
    video = MusicVideo.find_or_create_by!(slug: SLUG) do |v|
      v.kind = "cinematic"
      v.platform = "youtube"
      v.source_url = "https://www.youtube.com/watch?v=tiled-demo"
      v.source_id = "tiled-demo"
      v.title = "Test Artist A - Tiled Demo"
      v.duration_ms = DURATION_MS
      v.source_object_key = SOURCE
    end
    return video if video.video_performers.exists?

    artist = Artist.find_or_create_by!(name: ARTIST) { |a| a.assign_attributes(slug: Artist.available_slug(ARTIST), kind: "person") }
    MusicVideos::ReplacePerformers.new(video, PERFORMERS).call
    video.video_performers.each { |p| p.update!(p.ordinal == 1 ? { artist_slug: artist.slug } : { extra: true }) }
    video.confirm_cast!
    video
  end

  # The rows bin/find-clips --tile would post: the tiling, labelled from the cast.
  def self.chunk_rows(video = video!, duration_ms: DURATION_MS, **tiling)
    cast = video.video_performers.map { |p| p.as_json(only: %w[ordinal artist_slug extra sightings]) }
    MusicVideos::ChunkTiler.windows(duration_ms, **tiling).map do |w|
      seen = MusicVideos::ClipCast.label(cast, w.start_ms, w.end_ms)
      { "ordinal" => w.ordinal, "start_ms" => w.start_ms, "end_ms" => w.end_ms, "cast_shape" => seen.cast_shape,
        "target_performer" => seen.target, "performer_ordinals" => seen.present,
        "object_key" => MusicVideos::ObjectKeys.chunk(source_key: SOURCE, ordinal: w.ordinal, start_ms: w.start_ms, end_ms: w.end_ms) }
    end
  end

  def self.candidate_rows
    [CANDIDATE.merge(object_key: MusicVideos::ObjectKeys.clip(source_key: SOURCE, **CANDIDATE.slice(:ordinal, :seam, :cast_shape, :start_ms, :end_ms)))
              .transform_keys(&:to_s)]
  end

  # A take row as MusicVideos::StoreTake would record it, with no file behind it.
  def self.take!(chunk, number:, at: Time.current, byte_size: 2_048)
    video = chunk.music_video
    video.chunk_takes.create!(
      chunk_ordinal: chunk.ordinal, start_ms: chunk.start_ms, end_ms: chunk.end_ms, number:, byte_size:, current_since: at,
      original_filename: "generated_#{chunk.ordinal}_#{number}.mp4",
      object_key: MusicVideos::ObjectKeys.take(source_key: video.source_object_key, ordinal: chunk.ordinal,
                                               start_ms: chunk.start_ms, end_ms: chunk.end_ms, number:)
    )
  end

  def self.seed!
    video = video!
    MusicVideos::ReplaceClips.new(video, candidate_rows).call unless video.clip_candidates.exists?
    MusicVideos::ReplaceClips.new(video, chunk_rows(video), kind: "chunk").call unless video.video_chunks.exists?
    video
  end
end
