# The Night Call proof as seed data: the video bin/digest-video recorded, and the
# seven people the operator-reviewed index found (samples every 3 s, grouped by
# visible cues). No names are pre-filled; labelling them is the demo.
# Loaded by db/seeds/62_music_video_night_call.rb, e2e/seed.rb and the cast tests.
module NightCallCast
  SLUG = "steve-aoki-night-call".freeze
  FOLDER = "music_videos/steve_aoki/night_call/".freeze

  # The digest could not resolve Steve Aoki (not in the rapper-scoped Wikidata seed).
  ARTISTS = [
    { name: "Lil Yachty", kind: "person", wikidata_id: "Q23772141", aliases: ["Lil Boat", "Miles McCollum"] },
    { name: "Migos", kind: "group", wikidata_id: "Q15777045", aliases: [] },
    { name: "Quavo", kind: "person", wikidata_id: "Q30072039", aliases: ["Huncho"], group: "Migos" },
    { name: "Offset", kind: "person", wikidata_id: "Q30612480", aliases: [], group: "Migos" },
    { name: "Takeoff", kind: "person", wikidata_id: "Q48719890", aliases: [], group: "Migos" }
  ].freeze

  def self.t(mmss) = mmss.split(":").then { |m, s| (m.to_i * 60 + s.to_i) * 1000 }

  def self.sightings(clear, partial = "")
    clear.split.map { |c| { "t_ms" => t(c), "visibility" => "clear" } } +
      partial.split.map { |c| { "t_ms" => t(c), "visibility" => "partial" } }
  end

  PERFORMERS = [
    [1, "desk", "0230", "Desk scenes throughout. The longest solo run: 2:03 to 2:45.",
     sightings("0:18 0:21 0:24 0:27 0:30 1:03 1:09 2:06 2:12 2:18 2:24 2:27 2:30 2:33 2:36 2:39 2:42 2:45 3:33 3:39 3:45 3:48 3:54 3:57")],
    [2, "armchair", "0042", "Armchair scenes. Background only after 3:00.",
     sightings("0:33 0:39 0:42 0:45 0:48 0:51 0:54 0:57 1:00 2:51", "3:06 3:12 3:18 3:27")],
    [3, "long-haired man", "0106", "Mostly close-ups and the scenes with Person 4.",
     sightings("1:06 1:18 1:33 1:39 2:21 2:54", "1:30 1:36 1:45 2:00")],
    [4, "couch", "0121", "Couch scenes, 1:12 to 2:00.",
     sightings("1:12 1:18 1:21 1:27 1:30 1:36 1:42 1:45 1:48 1:51 1:54 1:57 2:00 2:48 3:51", "2:03")],
    [5, "supporting woman (with Person 6)", "0209",
     "Always seen with Person 6; which one is in each partial shot cannot be told from the samples.",
     sightings("1:15 2:09", "0:21 0:27 0:30 0:33 1:18 2:12 2:57")],
    [6, "supporting woman (with Person 5)", "0209",
     "Always seen with Person 5; the middle figure at 2:09 is a mannequin.",
     sightings("1:15 2:09", "0:21 0:27 0:30 0:33 1:18 2:12 2:57")],
    [7, "checkered glasses", "0309", "Couch scenes, 3:00 to 3:30. The 0:54 sighting is too small to confirm.",
     sightings("3:00 3:03 3:06 3:09 3:12 3:15 3:18 3:21 3:24 3:27 3:30 3:42", "0:54")]
  ].freeze

  def self.seed!
    artists = ARTISTS.to_h do |a|
      artist = Artist.find_by(wikidata_id: a[:wikidata_id]) ||
               Artist.create!(slug: Artist.available_slug(a[:name]), name: a[:name], kind: a[:kind],
                              wikidata_id: a[:wikidata_id])
      a[:aliases].each { |name| ArtistAlias.find_or_create_by!(artist_slug: artist.slug, name:, locale: "en") }
      [a[:name], artist]
    end
    ARTISTS.select { |a| a[:group] }.each do |a|
      ArtistMembership.find_or_create_by!(member_artist_slug: artists[a[:name]].slug,
                                          group_artist_slug: artists[a[:group]].slug)
    end

    video = MusicVideo.find_or_create_by!(slug: SLUG) do |v|
      v.platform = "youtube"
      v.source_url = "https://www.youtube.com/watch?v=Sa7GSJJ_lOo"
      v.source_id = "Sa7GSJJ_lOo"
      v.title = "Steve Aoki - Night Call feat. Lil Yachty & Migos (Official Video) [Ultra Music]"
      v.duration_ms = 242_000
      v.source_object_key = "#{FOLDER}source/steve_aoki_night_call_feat_lil_yachty_migos.mp4"
      v.info_object_key = "#{FOLDER}source/steve_aoki_night_call_feat_lil_yachty_migos.info.json"
      v.unresolved_credits = [{ "name" => "Steve Aoki", "role" => "primary", "reason" => "no_match" }]
    end
    [["Lil Yachty", 1], ["Migos", 2]].each do |name, position|
      MusicVideoArtist.find_or_create_by!(music_video_slug: video.slug, artist_slug: artists[name].slug) do |c|
        c.role = "featured"
        c.position = position
      end
    end

    return video if video.video_performers.exists?

    MusicVideos::ReplacePerformers.new(video, PERFORMERS.map do |ordinal, label, still, note, seen|
      { "ordinal" => ordinal, "label" => label, "confidence_note" => note, "sightings" => seen,
        "still_object_keys" => ["#{FOLDER}stills/person_#{format('%02d', ordinal)}_#{still}.jpg"] }
    end).call
    video
  end
end
