require_relative "tiled_video"

# The look dropdown on a cast card: a 72 s cinematic video with three people,
# a synthetic athlete who has three looks (one with a character sheet and the
# default, one with no sheet, one whose sheet is building) and a synthetic
# rookie with none. Person 1 and Person 3 are open; Person 2 is already recast
# into the athlete's finished look. For the tests, the e2e and the local demo.
#
# NOTHING HERE IS GENERATED: the "character sheet" is a drawing made below, and
# the building look has no job behind it. Wholly synthetic: a made-up video,
# visible cue labels, made-up athletes and team. The operator, never the agent,
# names who is on screen and who replaces them.
module LookPickerVideo
  SLUG = "test-cinematic-look-picker-demo".freeze
  SOURCE = "music_videos/test_cinematic/look_picker_demo/source/test_cinematic_look_picker_demo.mp4".freeze
  ATHLETE = { first_name: "Test", last_name: "Athlete Delta" }.freeze
  ROOKIE = { first_name: "Test", last_name: "Rookie Echo" }.freeze
  TEAM_SLUG = "test-city-testers".freeze
  FINISHED = "Home Orange".freeze
  BARE = "Away White".freeze
  BUILDING = "Alternate Blue".freeze
  PERFORMERS = (TiledVideo::PERFORMERS + [
    { "ordinal" => 3, "label" => "man in the grey hoodie", "confidence_note" => "Second half only.",
      "sightings" => [45, 48, 60].map { |s| { "t_ms" => s * 1000, "visibility" => "clear" } }, "still_object_keys" => [] }
  ]).freeze

  # A stand-in sheet in the real layout (two full-body figures, six head
  # views), drawn here so no generator is called and no bucket is read.
  def self.sheet_image(label, jersey: "#e8590c")
    heads = [520, 700, 880].product([110, 290]).map do |x, y|
      %(<circle cx="#{x + 60}" cy="#{y + 45}" r="34" fill="#b9bec7"/><rect x="#{x}" y="#{y + 85}" width="120" height="60" rx="18" fill="#{jersey}"/>)
    end
    bodies = [70, 290].map do |x|
      %(<circle cx="#{x + 70}" cy="95" r="36" fill="#b9bec7"/><rect x="#{x}" y="140" width="140" height="150" rx="24" fill="#{jersey}"/>) +
        %(<rect x="#{x + 22}" y="296" width="96" height="140" rx="14" fill="#8a909c"/>)
    end
    svg = %(<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1100 500" width="1100" height="500">) +
          %(<rect width="1100" height="500" fill="#d9dce1"/>#{bodies.join}#{heads.join}) +
          %(<text x="550" y="480" text-anchor="middle" font-family="sans-serif" font-size="22" fill="#4b5160">Synthetic test sheet · #{label}</text></svg>)
    "data:image/svg+xml;base64,#{Base64.strict_encode64(svg)}"
  end

  # A person with an athlete record and a cached headshot row, which is what
  # the sheet build reads as its anchor. The row is a key, never a fetch.
  def self.athlete_person!(names)
    person = Person.find_by(names) || Person.create!(athlete: true, **names)
    profile = Athlete.find_or_create_by!(person_slug: person.slug) do |athlete|
      athlete.sport = "football"
      athlete.team_slug = TEAM_SLUG
    end
    ImageCache.find_or_create_by!(owner: profile, purpose: "headshot", variant: "400") do |cache|
      cache.s3_key = "headshots/nfl/#{TEAM_SLUG}/#{person.slug}/400.png"
      cache.content_type = "image/png"
    end
    person
  end

  # hold: keeps the building look building past the stale window, for a demo
  # that sits open longer than a real build may run.
  def self.athlete!(hold: false)
    person = athlete_person!(ATHLETE)
    finished, _bare, building = [FINISHED, BARE, BUILDING].map { |descriptor| person.appearances.live.find_or_create_by!(descriptor:) }
    unless Artifact.newest_character_sheets([finished.slug]).key?(finished.slug)
      sheet = Artifact.create!(kind: "character_sheet", image_url: sheet_image(FINISHED), source: "seed")
      sheet.subjects.create!(person_slug: person.slug, appearance_slug: finished.slug, ordinal: 1)
    end
    building.update!(sheet_build_state: Appearances::SheetBuild::BUILDING,
                     sheet_build_started_at: hold ? 1.day.from_now : Time.current,
                     sheet_build_finished_at: nil, sheet_build_error: nil)
    person
  end

  def self.rookie! = athlete_person!(ROOKIE)

  def self.video!
    video = MusicVideo.find_or_create_by!(slug: SLUG) do |v|
      v.kind = "cinematic"
      v.platform = "youtube"
      v.source_url = "https://www.youtube.com/watch?v=look-picker-demo"
      v.source_id = "look-picker-demo"
      v.title = "Test Cinematic - Look Picker Demo"
      v.duration_ms = TiledVideo::DURATION_MS
      v.source_object_key = SOURCE
    end
    MusicVideos::ReplacePerformers.new(video, PERFORMERS).call unless video.video_performers.exists?
    video
  end

  def self.seed!(hold: false)
    athlete = athlete!(hold:)
    rookie!
    video = video!
    saved = video.video_performers.find_by!(ordinal: 2)
    if saved.recast_person_slug.blank? && !saved.recast_keep?
      look = athlete.appearances.live.find_by!(descriptor: FINISHED)
      MusicVideos::RecastPerformer.new(saved).call(person_slug: athlete.slug, appearance_slug: look.slug)
    end
    video
  end
end
