module MusicVideos
  # Who is swapped for whom in one version of a video: performer ordinal ->
  # the athlete and look that replace them. Two sources fill it: the cast card
  # as it stands (live, the cast page's working selection), and an alt video's
  # snapshot of it (AltVideo#swaps), which a later edit of the card never
  # changes. Prompts and hand-offs read a SwapSet, never the card directly.
  class SwapSet
    KEYS = %w[performer_ordinal person_slug appearance_slug person_name look_name].freeze

    Entry = Data.define(:performer_ordinal, :person_slug, :appearance_slug, :person_name, :look_name) do
      # "Test Athlete > Home Blue", or the athlete alone while the look is missing.
      def label = [person_name, look_name].compact.join(" > ")

      def to_row = to_h.transform_keys(&:to_s)
    end

    # The swaps the cast card holds now: swapped performers only (Keep Original
    # and no athlete both mean "stays as filmed").
    def self.live(performers)
      new(performers.select(&:swap?).map do |p|
        { "performer_ordinal" => p.ordinal, "person_slug" => p.recast_person_slug,
          "appearance_slug" => p.recast_appearance_slug.presence, "person_name" => p.swap_person&.full_name,
          "look_name" => p.swap_look&.descriptor }
      end)
    end

    def initialize(rows)
      @entries = Array(rows).map do |row|
        h = row.to_h.stringify_keys
        Entry.new(**KEYS.to_h { |k| [k.to_sym, h[k]] })
      end.sort_by(&:performer_ordinal).freeze
    end

    def [](ordinal) = @entries.find { |e| e.performer_ordinal == ordinal }

    def swapped?(ordinal) = !self[ordinal].nil?

    def to_a = @entries

    def empty? = @entries.empty?

    def size = @entries.size

    def to_rows = @entries.map(&:to_row)

    def appearance_slugs = @entries.filter_map(&:appearance_slug)
  end
end
