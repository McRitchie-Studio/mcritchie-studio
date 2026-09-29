# frozen_string_literal: true

module MusicVideos
  # Splits a video's credits into primary and featured artist names, from its
  # title first, then info.json's artist list, then the uploader. Pure Ruby: the
  # agent script (bin/digest-video) loads it without Rails.
  #
  # `known` answers "is this an artist name?" so a name holding a separator
  # ("Tyler, The Creator", "Earth, Wind & Fire") stays whole.
  class CreditParser
    Result = Struct.new(:primary, :featured, :song, keyword_init: true)

    FEAT_WORD = /(?:feat\.?|ft\.?|featuring)/i
    BRACKET_FEAT = /\s*[(\[]\s*(?:#{FEAT_WORD}|with)\s+([^)\]]+?)\s*[)\]]/i
    NOISE = /\s*[(\[][^)\]]*\b(?:official|video|audio|lyrics?|visuali[sz]er|music|hd|hq|4k|remaster(?:ed)?|explicit|clean|m\/v|mv)\b[^)\]]*[)\]]/i
    DASH = /\s+[-–—|]\s+/
    TRAILING_FEAT = /\s+#{FEAT_WORD}\s+(.+)\z/i
    ARTIST_SIDE_FEAT = /\s+(?:#{FEAT_WORD}|with)\s+(.+)\z/i
    NAME_SEP = /(\s*,\s*|\s+(?:&|and|x|X|×|\+|vs\.?)\s+)/

    def initialize(known: ->(_name) { false })
      @known = known
    end

    def parse(title:, uploader: nil, artists: [])
      featured = []
      text = title.to_s.gsub(BRACKET_FEAT) { featured.concat(names(Regexp.last_match(1))) && "" }
      text = text.gsub(NOISE, "").strip

      artist_side, song = text.split(DASH, 2)
      unless song
        song = artist_side
        artist_side = nil
      end
      song, song_feat = strip_feat(song.to_s, TRAILING_FEAT)
      featured.concat(names(song_feat)) if song_feat

      primary = []
      if artist_side
        artist_side, side_feat = strip_feat(artist_side, ARTIST_SIDE_FEAT)
        primary = names(artist_side)
        featured.concat(names(side_feat)) if side_feat
      end

      info = Array(artists).compact.map { |n| n.to_s.strip }.reject(&:empty?)
      primary = [info.shift] if primary.empty? && info.any?
      primary = [clean_uploader(uploader)].compact if primary.empty?
      featured.concat(info)

      primary = uniq(primary, [])
      Result.new(primary: primary, featured: uniq(featured, primary), song: song.strip)
    end

    private

    def strip_feat(text, pattern)
      match = text.match(pattern)
      return [text, nil] unless match

      [text[0...match.begin(0)], match[1]]
    end

    # Longest known run first, so a name holding a separator stays whole.
    def names(text)
      parts = text.to_s.strip.split(NAME_SEP)
      words = parts.each_slice(2).map(&:first)
      seps = parts.each_slice(2).map { |pair| pair[1] }
      out = []
      i = 0
      while i < words.size
        j = (words.size - 1).downto(i).find { |k| k == i || @known.call(join(words, seps, i, k)) }
        out << join(words, seps, i, j).strip
        i = j + 1
      end
      out.reject(&:empty?)
    end

    def join(words, seps, from, to)
      (from..to).map { |k| k == to ? words[k] : "#{words[k]}#{seps[k]}" }.join
    end

    def clean_uploader(uploader)
      name = uploader.to_s.sub(/\s*-\s*Topic\z/i, "").sub(/VEVO\z/i, "").sub(/\s+official\z/i, "").strip
      name.empty? ? nil : name
    end

    def uniq(list, taken)
      seen = taken.map(&:downcase)
      list.each_with_object([]) do |name, out|
        next if seen.include?(name.downcase)

        seen << name.downcase
        out << name
      end
    end
  end
end
