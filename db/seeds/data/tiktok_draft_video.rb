require_relative "tiled_video"

# A third tiled video for the TikTok draft's e2e and local demo (recast
# pipeline, piece 19): 45 s, two chunks, and its alt video 1 swapping Person 1
# into a synthetic athlete whose look carries a team (Buffalo Bills), so a
# caption can be written. Clip 1 holds a generated version (Draft to TikTok is
# on); clip 2 holds none (it is off). Its own video, so its spec never meets
# the specs that upload to and flag the tiled demo. Wholly synthetic: a made-up
# video and a made-up athlete; no file is behind any row.
module TiktokDraftVideo
  SLUG = "test-artist-a-tiktok-demo".freeze
  SOURCE = "music_videos/test_artist_a/tiktok_demo/source/test_artist_a_tiktok_demo.mp4".freeze
  DURATION_MS = 45_000
  ATHLETE = { first_name: "Test", last_name: "Rusher Eta" }.freeze
  LOOK = "Home Royal".freeze
  TEAM = "buffalo-bills".freeze
  CLIP = "#{SLUG}-alt-1-clip-01".freeze

  def self.athlete!
    person = Person.find_by(ATHLETE) || Person.create!(athlete: true, **ATHLETE)
    look = person.appearances.live.find_or_create_by!(descriptor: LOOK) { |l| l.team_slug = TEAM }
    [person, look]
  end

  def self.seed!
    person, look = athlete!
    video = TiledVideo.video!(slug: SLUG, source: SOURCE, source_id: "tiktok-demo", title: "Test Artist A - TikTok Demo",
                              duration_ms: DURATION_MS)
    MusicVideos::ReplaceClips.new(video, TiledVideo.chunk_rows(video), kind: "chunk").call unless video.video_chunks.exists?
    unless video.alt_videos.exists?
      video.video_performers.find_by!(ordinal: 1)
           .update!(recast_person_slug: person.slug, recast_appearance_slug: look.slug, recast_keep: false)
      AltVideo.build_from!(video.reload)
    end
    first = video.alt_videos.first.clips.first
    TiledVideo.version!(first, number: 1) if first.versions.empty?
    video
  end
end
