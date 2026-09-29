# Night Call with a confirmed cast and two clip candidates, for the clips tests
# and e2e. A separate record from NightCallCast's, whose cast stays unlabelled
# for the cast-panel demo. The windows are ones bin/find-clips proposed.
require_relative "night_call_cast"

module NightCallClips
  SLUG = "steve-aoki-night-call-clips".freeze
  SOURCE = "music_videos/steve_aoki/night_call_clips/source/steve_aoki_night_call_clips.mp4".freeze
  LINKS = { 1 => "Lil Yachty", 3 => "Quavo", 4 => "Offset", 7 => "Takeoff" }.freeze
  CLIPS = [
    { ordinal: 1, start_ms: 17_500, end_ms: 42_084, seam: "chorus_to_verse", seam_ms: 33_500,
      cast_shape: "solo_plus_background", target_performer: 1, performer_ordinals: [1, 2, 5, 6] },
    { ordinal: 2, start_ms: 108_000, end_ms: 132_758, seam: "singer_change", seam_ms: 123_000,
      cast_shape: "duo_plus_background", target_performer: 4, performer_ordinals: [1, 3, 4, 5, 6] }
  ].freeze

  def self.video!
    NightCallCast.seed! # the artists
    video = MusicVideo.find_or_create_by!(slug: SLUG) do |v|
      v.platform = "youtube"
      v.source_url = "https://www.youtube.com/watch?v=Sa7GSJJ_lOo"
      v.source_id = "night-call-clips-demo"
      v.title = "Steve Aoki - Night Call feat. Lil Yachty & Migos (clips demo)"
      v.duration_ms = 242_000
      v.source_object_key = SOURCE
    end
    return video if video.video_performers.exists?

    MusicVideos::ReplacePerformers.new(video, NightCallCast::PERFORMERS.map do |ordinal, label, _still, note, seen|
      { "ordinal" => ordinal, "label" => label, "confidence_note" => note, "sightings" => seen, "still_object_keys" => [] }
    end).call
    video.video_performers.each do |p|
      name = LINKS[p.ordinal]
      p.update!(name ? { artist_slug: Artist.find_by!(name:).slug } : { extra: true })
    end
    video.confirm_cast!
    video
  end

  def self.rows
    CLIPS.map do |c|
      c.merge(object_key: MusicVideos::ObjectKeys.clip(source_key: SOURCE, **c.slice(:ordinal, :seam, :cast_shape, :start_ms, :end_ms)))
       .transform_keys(&:to_s)
    end
  end

  def self.seed!
    video = video!
    MusicVideos::ReplaceClips.new(video, rows).call unless video.video_clips.exists?
    video
  end
end
