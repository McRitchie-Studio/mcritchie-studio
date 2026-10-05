module MusicVideosHelper
  # 83_000 -> "1:23"
  def video_timecode(ms)
    total = ms.to_i / 1000
    format("%d:%02d", total / 60, total % 60)
  end

  # 25_000 -> "25", 7_500 -> "7.5"
  def clip_seconds(ms) = format("%g", ms / 1000.0)

  CLIP_SEAM_LABELS = {
    "verse_to_chorus" => "Verse → chorus", "chorus_to_verse" => "Chorus → verse",
    "singer_change" => "Singer change", "section_change" => "Section change", "unknown" => "Seam unknown"
  }.freeze

  def clip_seam_label(seam) = CLIP_SEAM_LABELS.fetch(seam, seam.to_s.humanize)

  # "duo_plus_background" -> "Duo + background"
  def clip_shape_label(shape) = shape.to_s.sub("_plus_background", " + background").humanize
end
