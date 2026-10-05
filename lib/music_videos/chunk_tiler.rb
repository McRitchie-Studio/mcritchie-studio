# frozen_string_literal: true

module MusicVideos
  # Tiles a whole video into fixed chunks for the recast pipeline: 25 s chunks
  # on a 20 s stride, so neighbours share 5 s (0-25, 20-45, 40-65 ...). The last
  # chunk ends at the video's end and may be shorter. A tail the previous chunk
  # already covers makes no extra chunk. Pure Ruby; no seam, no audio.
  module ChunkTiler
    CHUNK_MS = 25_000
    STRIDE_MS = 20_000
    OVERLAP_MS = CHUNK_MS - STRIDE_MS
    # How far the file on disk may differ from the recorded duration and still
    # be the same video (two probes of one MP4 agree to the millisecond).
    END_TOLERANCE_MS = 1_000

    Window = Data.define(:ordinal, :start_ms, :end_ms)

    module_function

    def windows(duration_ms)
      raise ArgumentError, "a duration in whole milliseconds above zero is required" unless duration_ms.is_a?(Integer) && duration_ms.positive?

      list = []
      start = 0
      loop do
        finish = [start + CHUNK_MS, duration_ms].min
        list << Window.new(ordinal: list.size + 1, start_ms: start, end_ms: finish)
        return list if finish >= duration_ms

        start += STRIDE_MS
      end
    end

    # Where chunk N starts: the stride is fixed, so the ordinal alone says.
    def start_of(ordinal) = (ordinal - 1) * STRIDE_MS
  end
end
