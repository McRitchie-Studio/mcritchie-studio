module MusicVideosHelper
  # 83_000 -> "1:23"
  def video_timecode(ms)
    total = ms.to_i / 1000
    format("%d:%02d", total / 60, total % 60)
  end
end
