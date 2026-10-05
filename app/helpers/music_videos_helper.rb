module MusicVideosHelper
  # 83_000 -> "1:23"
  def video_timecode(ms)
    total = ms.to_i / 1000
    format("%d:%02d", total / 60, total % 60)
  end

  # 25_000 -> "25", 7_500 -> "7.5"
  def clip_seconds(ms) = format("%g", ms / 1000.0)

  # 12_582_912 -> "12.0 MB"
  def take_size(bytes) = number_to_human_size(bytes, precision: 1, significant: false, strip_insignificant_zeros: false)

  # What the stitch preview player reads: when each chunk is on screen
  # (MusicVideos::StitchTimeline) and the file it plays there, its current
  # take or, with none, its own source cut. urls is object key => signed URL.
  def stitch_preview_data(chunks, urls)
    segments = MusicVideos::StitchTimeline.segments(chunks)
    { duration_ms: MusicVideos::StitchTimeline.duration_ms(segments),
      segments: segments.zip(chunks).map do |segment, chunk|
        take = chunk.current_take
        segment.to_h.merge(url: urls[chunk.playback_object_key], source: take.nil?,
                           label: take ? take.name.downcase : "source", flagged: chunk.regenerate_requested?)
      end }
  end

  CLIP_SEAM_LABELS = {
    "verse_to_chorus" => "Verse → chorus", "chorus_to_verse" => "Chorus → verse",
    "singer_change" => "Singer change", "section_change" => "Section change", "unknown" => "Seam unknown"
  }.freeze

  def clip_seam_label(seam) = CLIP_SEAM_LABELS.fetch(seam, seam.to_s.humanize)

  # "duo_plus_background" -> "Duo + background"
  def clip_shape_label(shape) = shape.to_s.sub("_plus_background", " + background").humanize
end
