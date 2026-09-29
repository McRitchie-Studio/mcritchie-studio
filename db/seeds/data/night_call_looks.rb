# Night Call with a confirmed cast whose two labelled people have stills, for
# the looks tests and e2e (pipeline stage 4). A separate record in the same R2
# folder as NightCallCast, so local stills that exist there render. Labels are
# synthetic test artists: only the operator maps an on-screen person to a real one.
require_relative "night_call_cast"

module NightCallLooks
  SLUG = "steve-aoki-night-call-looks".freeze
  FOLDER = NightCallCast::FOLDER
  LINKS = { 1 => "Test Artist A", 2 => "Test Artist B" }.freeze
  # Person 2's partial still is posted first, to show the look ranks clear first.
  STILLS = {
    1 => %w[0230 0021],
    2 => %w[0306 0042]
  }.freeze

  def self.seed!
    NightCallCast.seed!
    video = MusicVideo.find_or_create_by!(slug: SLUG) do |v|
      v.platform = "youtube"
      v.source_url = "https://www.youtube.com/watch?v=Sa7GSJJ_lOo"
      v.source_id = "night-call-looks-demo"
      v.title = "Night Call (looks demo)"
      v.duration_ms = 242_000
      v.source_object_key = "#{FOLDER}source/steve_aoki_night_call_feat_lil_yachty_migos.mp4"
    end
    return video if video.video_performers.exists?

    LINKS.each_value do |name|
      Artist.find_or_create_by!(name:) { |a| a.assign_attributes(slug: Artist.available_slug(name), kind: "person") }
    end
    MusicVideos::ReplacePerformers.new(video, NightCallCast::PERFORMERS.map do |ordinal, label, still, note, seen|
      stills = STILLS.fetch(ordinal, [still]).map { |mmss| "#{FOLDER}stills/person_#{format('%02d', ordinal)}_#{mmss}.jpg" }
      { "ordinal" => ordinal, "label" => label, "confidence_note" => note, "sightings" => seen, "still_object_keys" => stills }
    end).call
    video.video_performers.each do |p|
      name = LINKS[p.ordinal]
      p.update!(name ? { artist_slug: Artist.find_by!(name:).slug } : { extra: true })
    end
    video.confirm_cast!
    video
  end
end
