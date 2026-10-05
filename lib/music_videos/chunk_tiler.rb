# frozen_string_literal: true

module MusicVideos
  # Tiles a whole video into fixed chunks for the recast pipeline. By default
  # 25 s chunks that share 5 s with the one before, so a 20 s stride (0-25,
  # 20-45, 40-65 ...). Both are parameters: the swap model sets how long a
  # chunk may be. The last chunk ends at the video's end and may be shorter. A
  # tail the previous chunk already covers makes no extra chunk. Pure Ruby; no
  # seam, no audio.
  module ChunkTiler
    CHUNK_MS = 25_000
    OVERLAP_MS = 5_000
    STRIDE_MS = CHUNK_MS - OVERLAP_MS
    # How far the file on disk may differ from the recorded duration and still
    # be the same video (two probes of one MP4 agree to the millisecond).
    END_TOLERANCE_MS = 1_000

    Window = Data.define(:ordinal, :start_ms, :end_ms)

    module_function

    def windows(duration_ms, chunk_ms: CHUNK_MS, overlap_ms: OVERLAP_MS)
      raise ArgumentError, "a duration in whole milliseconds above zero is required" unless duration_ms.is_a?(Integer) && duration_ms.positive?

      step = stride(chunk_ms:, overlap_ms:)
      list = []
      start = 0
      loop do
        finish = [start + chunk_ms, duration_ms].min
        list << Window.new(ordinal: list.size + 1, start_ms: start, end_ms: finish)
        return list if finish >= duration_ms

        start += step
      end
    end

    # nil when the pair can tile; else why not.
    def problem(chunk_ms:, overlap_ms:)
      return "the chunk length must be whole milliseconds above zero" unless chunk_ms.is_a?(Integer) && chunk_ms.positive?
      return "the overlap must be whole milliseconds, zero or more" unless overlap_ms.is_a?(Integer) && overlap_ms >= 0

      "the overlap (#{overlap_ms} ms) must be shorter than the chunk (#{chunk_ms} ms)" if overlap_ms >= chunk_ms
    end

    def stride(chunk_ms: CHUNK_MS, overlap_ms: OVERLAP_MS)
      why = problem(chunk_ms:, overlap_ms:)
      raise ArgumentError, why if why

      chunk_ms - overlap_ms
    end

    # Where chunk N starts: the stride is fixed, so the ordinal alone says.
    def start_of(ordinal, chunk_ms: CHUNK_MS, overlap_ms: OVERLAP_MS) = (ordinal - 1) * stride(chunk_ms:, overlap_ms:)
  end
end
