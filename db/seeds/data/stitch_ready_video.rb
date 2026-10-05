require_relative "tiled_video"

# A second tiled video for the final stitch's e2e: 45 s, two chunks (0-25 and
# 20-45), chunk 1 with a generated take and chunk 2 with none, so the operator
# is one upload away from "Generate full video". Its own video, so the spec
# never meets the specs that upload to and flag the tiled demo. Wholly
# synthetic, built from TiledVideo's cast; no file is behind any row.
module StitchReadyVideo
  SLUG = "test-artist-a-stitch-demo".freeze
  SOURCE = "music_videos/test_artist_a/stitch_demo/source/test_artist_a_stitch_demo.mp4".freeze
  DURATION_MS = 45_000

  def self.seed!
    video = TiledVideo.video!(slug: SLUG, source: SOURCE, source_id: "stitch-demo", title: "Test Artist A - Stitch Demo",
                              duration_ms: DURATION_MS)
    MusicVideos::ReplaceClips.new(video, TiledVideo.chunk_rows(video), kind: "chunk").call unless video.video_chunks.exists?
    first = video.video_chunks.first
    TiledVideo.take!(first, number: 1) if first.takes.empty?
    video
  end
end
