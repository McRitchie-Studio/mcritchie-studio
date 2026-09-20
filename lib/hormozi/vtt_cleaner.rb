# frozen_string_literal: true

module Hormozi
  # Turns a YouTube auto-caption VTT file into readable prose.
  #
  # Auto-captions are a ROLLING WINDOW, not a transcript: each cue repeats the
  # tail of the cue before it and adds a few new words, and every cue is emitted
  # twice — once carrying inline `<00:00:04.480><c> word</c>` timings, once
  # plain. Concatenating the cue text therefore says everything about three
  # times, which is both unreadable and triple the tokens to extract from. Every
  # incoming line is merged onto the accumulated words by its LONGEST word
  # overlap, so a cue that merely repeats its predecessor appends nothing.
  module VttCleaner
    CUE_TIMING = /\A\d{2}:\d{2}:\d{2}\.\d{3}\s+-->/
    METADATA_LINE = /\A(WEBVTT|Kind:|Language:|NOTE\b|STYLE\b)/
    CUE_SEQUENCE = /\A\d+\z/
    INLINE_TAG = /<[^>]*>/

    # yt-dlp writes the caption as `<video-id>.<language-tag>.vtt`, and the tag is
    # whatever --sub-langs asked for. A REGION-CODED tag is capitalized or carries
    # digits (`.en-US.vtt`, `.pt-BR.vtt`, `.es-419.vtt`), so a lowercase-only class
    # stripped only `.vtt` and left the tag ON the id: the metadata lookup missed,
    # the title fell back to the filename, and a real episode tiered at 3 at exit
    # 0. The class is anchored between a dot and `.vtt`, and YouTube ids carry no
    # dots, so widening it cannot swallow part of an id.
    LANGUAGE_TAG = /\.[A-Za-z0-9-]+\.vtt\z/

    # The longest overlap worth hunting for. Auto-caption cues carry a handful
    # of words; scanning further costs time and invites false matches.
    MAX_OVERLAP_WORDS = 24

    ENTITIES = {
      "&amp;" => "&",
      "&lt;" => "<",
      "&gt;" => ">",
      "&quot;" => '"',
      "&#39;" => "'",
      "&apos;" => "'",
      "&nbsp;" => " "
    }.freeze

    # The video id a caption file belongs to. A file with no language tag at all
    # (`<video-id>.vtt`) keeps its bare id.
    def self.video_id(path)
      File.basename(path).sub(LANGUAGE_TAG, "").sub(/\.vtt\z/, "")
    end

    # Returns the VTT's spoken words as one plain string.
    def self.clean(vtt)
      words = []
      vtt.to_s.each_line do |raw|
        line = normalize(raw)
        next if line.empty?

        merge(words, line.split)
      end
      words.join(" ")
    end

    # Strips a single VTT line to its spoken text, or "" when the line carries
    # no speech (headers, cue timings, cue numbers, blank separators).
    def self.normalize(raw)
      line = raw.strip
      return "" if line.empty?
      return "" if line.match?(METADATA_LINE)
      return "" if line.match?(CUE_TIMING)
      return "" if line.match?(CUE_SEQUENCE)

      line = line.gsub(INLINE_TAG, " ")
      ENTITIES.each { |entity, char| line = line.gsub(entity, char) }
      line.gsub(/\s+/, " ").strip
    end

    # Appends only the part of `incoming` that the tail of `words` does not
    # already say. Mutates and returns `words`.
    def self.merge(words, incoming)
      return words if incoming.empty?

      limit = [words.length, incoming.length, MAX_OVERLAP_WORDS].min
      limit.downto(1) do |overlap|
        next unless words.last(overlap) == incoming.first(overlap)

        return words.concat(incoming.drop(overlap))
      end

      words.concat(incoming)
    end
  end
end
