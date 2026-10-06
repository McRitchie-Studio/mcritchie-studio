require_relative "tiled_video"

# An open cast card for the two typeaheads' rows (headshot or placeholder,
# primary vocation, team): a 72 s cinematic video with one unanswered person,
# and a synthetic athlete on a team who has no look yet, for "Replaced by" to
# find and offer a look for. For the e2e and the local demo. Wholly synthetic:
# a made-up video, a visible cue label, a made-up athlete and team. The
# operator, never the agent, names who is on screen and who replaces them.
module SearchRowsVideo
  SLUG = "test-cinematic-search-rows-demo".freeze
  SOURCE = "music_videos/test_cinematic/search_rows_demo/source/test_cinematic_search_rows_demo.mp4".freeze
  ROOKIE = { first_name: "Test", last_name: "Rookie Bravo" }.freeze
  # A non-sports person for the naming search ("Who is this on screen?"),
  # which leaves athletes to the swap search.
  ACTOR = { first_name: "Test", last_name: "Actor Delta" }.freeze
  # No teams row on purpose: the row reads the slug in words, as production
  # does for an athlete whose team was never seeded.
  TEAM_SLUG = "test-city-testers".freeze
  # A local asset, so the headshot loads without leaving the app.
  AVATAR = "/icon.png".freeze

  def self.rookie!
    person = Person.find_by(ROOKIE) || Person.create!(athlete: true, avatar_url: AVATAR, **ROOKIE)
    Athlete.find_or_create_by!(person_slug: person.slug) do |athlete|
      athlete.sport = "football"
      athlete.team_slug = TEAM_SLUG
    end
    person
  end

  def self.actor!
    Person.find_by(ACTOR) || Person.create!(primary_vocation: "actor", vocations: ["actor"], avatar_url: AVATAR, **ACTOR)
  end

  def self.video!
    video = MusicVideo.find_or_create_by!(slug: SLUG) do |v|
      v.kind = "cinematic"
      v.platform = "youtube"
      v.source_url = "https://www.youtube.com/watch?v=search-rows-demo"
      v.source_id = "search-rows-demo"
      v.title = "Test Cinematic - Search Rows Demo"
      v.duration_ms = TiledVideo::DURATION_MS
      v.source_object_key = SOURCE
    end
    MusicVideos::ReplacePerformers.new(video, TiledVideo::PERFORMERS.first(1)).call unless video.video_performers.exists?
    video
  end

  def self.seed!
    rookie!
    actor!
    video!
  end
end
