require_relative "tiled_video"
require_relative "look_picker_video"

# A 72 s cinematic video for lettered clip references (recast pipeline, piece
# 16): three people, two of them swapped in alt video 1, each look with a
# jersey number, and chunk 3 (0:40-1:05) carrying lettered reference frames.
#
#   Person A  man in the red coat     on screen throughout, kept as filmed
#   Person B  woman in the blue dress  leads 0:40-1:05     -> Test Passer Epsilon, Home White (#4)
#   Person C  man in the green cap     in the back 0:45-1:00 -> Test Receiver Zeta, Home White (#88)
#
# So chunk 3's prompt lists B as the lead and C as background, sheets 1 and 2.
# For the lettered-reference tests, the e2e and the local demo. Wholly
# synthetic: a made-up video, visible-cue labels, made-up athletes. The letters
# are not names; only the operator says who is on screen.
module LetteredVideo
  SLUG = "test-artist-b-lettered-demo".freeze
  SOURCE = "music_videos/test_artist_b/lettered_demo/source/test_artist_b_lettered_demo.mp4".freeze
  DURATION_MS = TiledVideo::DURATION_MS
  # Their own synthetic athletes, so no other demo's prompts gain a number.
  ATHLETES = [[{ first_name: "Test", last_name: "Passer Epsilon" }, "Home White", 4],
              [{ first_name: "Test", last_name: "Receiver Zeta" }, "Home White", 88]].freeze
  clear = ->(seconds) { seconds.map { |s| { "t_ms" => s * 1000, "visibility" => "clear" } } }
  PERFORMERS = [
    { "ordinal" => 1, "label" => "man in the red coat", "confidence_note" => "On screen throughout.",
      "sightings" => clear.call((3..69).step(3)), "still_object_keys" => [] },
    { "ordinal" => 2, "label" => "woman in the blue dress", "confidence_note" => "Leads the third chunk.",
      "sightings" => clear.call((42..63).step(3)), "still_object_keys" => [] },
    { "ordinal" => 3, "label" => "man in the green cap", "confidence_note" => "Background, behind the woman.",
      "sightings" => [48, 54, 57].map { |s| { "t_ms" => s * 1000, "visibility" => "partial" } }, "still_object_keys" => [] }
  ].freeze
  # Where the people stand in the synthetic source (bin/clip-references tags),
  # as fractions of the frame: what an agent reads off the frames by eye.
  TAGS = { "A" => [0.18, 0.55], "B" => [0.5, 0.5], "C" => [0.8, 0.42] }.freeze
  FRAMES = [[45_000, %w[A B C]], [54_000, %w[A B C]]].freeze

  # [[person, look]] for Person B and Person C, each look with a synthetic
  # character sheet (LookPickerVideo.sheet_image), so the card offers both.
  def self.athletes!
    ATHLETES.map do |name, descriptor, number|
      person = Person.find_by(name) || Person.create!(athlete: true, **name)
      look = person.appearances.live.find_or_create_by!(descriptor:) { |l| l.jersey_number = number }
      unless Artifact.newest_character_sheets([look.slug]).key?(look.slug)
        sheet = Artifact.create!(kind: "character_sheet", image_url: LookPickerVideo.sheet_image(descriptor, jersey: "#f4f4f4"), source: "seed")
        sheet.subjects.create!(person_slug: person.slug, appearance_slug: look.slug, ordinal: 1)
      end
      [person, look]
    end
  end

  def self.video!
    video = MusicVideo.find_or_create_by!(slug: SLUG) do |v|
      v.kind = "cinematic"
      v.platform = "youtube"
      v.source_url = "https://www.youtube.com/watch?v=lettered-demo"
      v.source_id = "lettered-demo"
      v.title = "Test Artist B - Lettered Demo"
      v.duration_ms = DURATION_MS
      v.source_object_key = SOURCE
    end
    return video if video.video_performers.exists?

    MusicVideos::ReplacePerformers.new(video, PERFORMERS).call
    video.video_performers.each { |p| p.update!(recast_keep: true) }
    video.confirm_cast!
    video
  end

  def self.chunk_rows(video = video!)
    cast = video.video_performers.map { |p| p.as_json(only: %w[ordinal artist_slug extra sightings]) }
    MusicVideos::ChunkTiler.windows(DURATION_MS).map do |w|
      seen = MusicVideos::ClipCast.label(cast, w.start_ms, w.end_ms)
      { "ordinal" => w.ordinal, "start_ms" => w.start_ms, "end_ms" => w.end_ms, "cast_shape" => seen.cast_shape,
        "target_performer" => seen.target, "performer_ordinals" => seen.present,
        "object_key" => MusicVideos::ObjectKeys.chunk(source_key: SOURCE, ordinal: w.ordinal, start_ms: w.start_ms, end_ms: w.end_ms) }
    end
  end

  # Chunk 3's frames as bin/clip-references --apply posts them.
  def self.frames(chunk)
    FRAMES.each_with_index.map do |(t_ms, letters), i|
      { "object_key" => MusicVideos::ObjectKeys.chunk_reference(source_key: SOURCE, ordinal: chunk.ordinal, start_ms: chunk.start_ms,
                                                                end_ms: chunk.end_ms, number: i + 1),
        "t_ms" => t_ms, "letters" => letters }
    end
  end

  def self.seed!
    swaps = athletes!
    video = video!
    MusicVideos::ReplaceClips.new(video, chunk_rows(video), kind: "chunk").call unless video.video_chunks.exists?
    unless video.alt_videos.exists?
      swaps.each.with_index(2) do |(person, look), ordinal|
        video.video_performers.find_by!(ordinal:)
             .update!(recast_person_slug: person.slug, recast_appearance_slug: look.slug, recast_keep: false)
      end
      AltVideo.build_from!(video.reload)
    end
    chunk = video.video_chunks.find_by!(ordinal: 3)
    chunk.update!(reference_frames: frames(chunk)) if chunk.reference_frames.empty?
    MusicVideos::ClipPrompts.refresh!(video)
    video
  end
end
