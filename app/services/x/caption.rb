module X
  # Assembles and measures the text of a post. Pure logic — no HTTP, no Rails.
  #
  # The split it serves: a soul decides the WORDS and which tags fit; this decides
  # whether the result is a post X will take. Length is X's WEIGHTED count, not
  # String#length: most Latin text weighs 1, an emoji or a CJK character weighs
  # 2, and any URL weighs 23 whatever its real length.
  class Caption
    MAX_WEIGHT    = 280
    URL_WEIGHT    = 23
    MAX_HASHTAGS  = 8
    HASHTAG       = /\A#[A-Za-z0-9_]+\z/
    HANDLE        = /\A@[A-Za-z0-9_]{1,15}\z/
    URL           = %r{https?://\S+}
    # Code point ranges X counts as 1. Everything else counts as 2.
    LIGHT_RANGES  = [0..4351, 8192..8205, 8208..8223, 8242..8247].freeze

    attr_reader :line, :hashtags, :handles

    def initialize(line:, hashtags: [], handles: [])
      @line     = line.to_s.strip
      @hashtags = hashtags.map { |t| t.to_s.strip }.reject(&:empty?)
      @handles  = handles.map { |h| h.to_s.strip }.reject(&:empty?)
    end

    # The line, then one tail line of handles and hashtags. A tag already written
    # into the line is not repeated in the tail.
    def text
      tail = (handles + hashtags).reject { |t| line.downcase.include?(t.downcase) }
      tail.empty? ? line : "#{line}\n\n#{tail.join(' ')}"
    end

    def weight
      self.class.weight(text)
    end

    def self.weight(text)
      urls = text.scan(URL)
      bare = text.gsub(URL, "")
      urls.size * URL_WEIGHT + bare.each_char.sum { |c| LIGHT_RANGES.any? { |r| r.cover?(c.ord) } ? 1 : 2 }
    end

    def link?
      text.match?(URL)
    end

    # Everything that makes this caption unpostable, as sentences. Empty means go.
    def problems
      out = []
      out << "the line is empty" if line.empty?
      out << "weighs #{weight}, over X's #{MAX_WEIGHT}" if weight > MAX_WEIGHT
      bad = hashtags.reject { |t| t.match?(HASHTAG) }
      out << "not a hashtag: #{bad.join(', ')} (one word, leading #, letters digits underscore)" if bad.any?
      bad = handles.reject { |h| h.match?(HANDLE) }
      out << "not a handle: #{bad.join(', ')}" if bad.any?
      total = text.scan(/#[A-Za-z0-9_]+/).uniq.size
      out << "#{total} hashtags, over the #{MAX_HASHTAGS} this account allows itself" if total > MAX_HASHTAGS
      out
    end
  end
end
