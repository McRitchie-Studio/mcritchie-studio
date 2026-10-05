# frozen_string_literal: true

module MusicVideos
  # Where each chunk plays when the chunks run back to back as one video (the
  # stitch preview, and the final stitch after it). Neighbouring chunks share
  # an overlap; chunk N hands over to N+1 at the MIDDLE of it. So chunk N is on
  # screen from the handover with N-1 to the handover with N+1, the first from
  # its own start and the last to its own end.
  #
  # Timed from each chunk's recorded window (start_ms, end_ms) alone, never
  # from a file's length: cut files run a frame long and a generated take may
  # differ slightly. Pure Ruby; takes anything with ordinal, start_ms, end_ms.
  module StitchTimeline
    # from_ms...to_ms is when the chunk is on screen, on the video's own clock.
    Segment = Data.define(:ordinal, :start_ms, :end_ms, :from_ms, :to_ms) do
      def cover?(t_ms) = t_ms >= from_ms && t_ms < to_ms

      # How far into the chunk's own file the video clock t_ms falls.
      def offset_ms(t_ms) = t_ms - start_ms
    end

    module_function

    # The chunks in time order -> one Segment each. Raises on windows that do
    # not run forward: a stitch over them would play out of order.
    def segments(windows)
      list = windows.to_a
      list.each_cons(2) do |left, right|
        next if right.start_ms > left.start_ms && right.end_ms > left.end_ms

        raise ArgumentError, "chunk #{right.ordinal} does not run on from chunk #{left.ordinal}"
      end
      cuts = list.each_cons(2).map { |left, right| handover_ms(left, right) }
      list.each_with_index.map do |w, i|
        Segment.new(ordinal: w.ordinal, start_ms: w.start_ms, end_ms: w.end_ms,
                    from_ms: i.zero? ? w.start_ms : cuts[i - 1], to_ms: cuts[i] || w.end_ms)
      end
    end

    # The middle of the overlap two neighbours share. With no overlap (a plain
    # cut, or a gap) the next chunk takes over where it starts.
    def handover_ms(left, right)
      return right.start_ms if left.end_ms <= right.start_ms

      (right.start_ms + left.end_ms) / 2
    end

    # The segment on screen at t_ms; the first before the start, the last at
    # or past the end. nil for no segments.
    def segment_at(segments, t_ms)
      segments.reverse_each.find { |s| t_ms >= s.from_ms } || segments.first
    end

    def duration_ms(segments) = segments.last&.to_ms.to_i
  end
end
