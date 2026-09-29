# frozen_string_literal: true

module MusicVideos
  # Reads a WebVTT caption file into cue timings and section markers. The text
  # is read only to tell a sung line from a "[Music]" tag and is then dropped:
  # lyric text is never stored.
  module VttTiming
    TIME = /(?:(\d+):)?(\d{2}):(\d{2})[.,](\d{3})/
    CUE_LINE = /\A\s*#{TIME}\s+-->\s+#{TIME}/
    MIN_CUE_MS = 50       # YouTube auto-subs repeat each line as a ~10 ms cue
    SECTION_GAP_MS = 2_000
    INSTRUMENTAL = /\A(?:\s|♪|\[[^\]]*\])+\z/

    module_function

    def parse(vtt)
      cues = read_cues(vtt.to_s)
      {
        "cues" => cues.reject { |c| c[:instrumental] }.map { |c| { "start_ms" => c[:start], "end_ms" => c[:end] } },
        "sections" => sections(cues)
      }
    end

    def read_cues(vtt)
      vtt.split(/\r?\n\s*\r?\n/).filter_map do |block|
        lines = block.lines.map(&:strip)
        index = lines.index { |l| l.match?(CUE_LINE) }
        next unless index

        m = lines[index].match(CUE_LINE)
        start = ms(m[1], m[2], m[3], m[4])
        finish = ms(m[5], m[6], m[7], m[8])
        text = lines[(index + 1)..].join(" ").gsub(/<[^>]*>/, "").strip
        next if text.empty? || finish - start < MIN_CUE_MS

        { start: start, end: finish, instrumental: text.match?(INSTRUMENTAL) }
      end
    end

    def sections(cues)
      cues.each_with_object([]) do |cue, out|
        kind = cue[:instrumental] ? "instrumental" : "vocal"
        last = out.last
        if last && last["kind"] == kind && cue[:start] - last["end_ms"] < SECTION_GAP_MS
          last["end_ms"] = [last["end_ms"], cue[:end]].max
        else
          out << { "kind" => kind, "start_ms" => cue[:start], "end_ms" => cue[:end] }
        end
      end
    end

    def ms(hours, minutes, seconds, millis)
      ((hours.to_i * 60 + minutes.to_i) * 60 + seconds.to_i) * 1000 + millis.to_i
    end
  end
end
