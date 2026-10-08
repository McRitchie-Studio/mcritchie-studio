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

  # A video src that opens on its first frame instead of a black box: the
  # media fragment starts the element a millisecond in, so a browser paints
  # frame 1 once it has the metadata (iOS Safari only paints with it). The
  # fragment never reaches the server, so a signed URL's signature still holds;
  # clipPair() seeks the same millisecond for any browser that ignores it.
  def first_frame_src(url)
    return url if url.blank? || url.include?("#")

    "#{url}#t=0.001"
  end

  # What the Watch full video player reads for an alt video: when each clip
  # is on screen (MusicVideos::StitchTimeline, handover mid-overlap) and the
  # file it plays there, its primary version or, with none, the source chunk.
  # chunk_for is clip ordinal => source chunk; urls is object key => signed URL.
  # Each segment carries its object key, so the page can swap in a fresh URL.
  def alt_watch_data(clips, chunk_for, urls)
    segments = MusicVideos::StitchTimeline.segments(clips)
    { duration_ms: MusicVideos::StitchTimeline.duration_ms(segments),
      segments: segments.zip(clips).map do |segment, clip|
        version = clip.primary_version
        key = version&.object_key || chunk_for[clip.chunk_ordinal]&.object_key
        segment.to_h.merge(key:, url: key && urls[key], source: version.nil?,
                           label: version ? version.name.downcase : "source", flagged: clip.regenerate_requested?)
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
