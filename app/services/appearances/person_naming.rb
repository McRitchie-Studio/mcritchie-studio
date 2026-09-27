module Appearances
  # DOES THIS PHOTOGRAPH'S TITLE NAME OUR PERSON, SOMEBODY ELSE, OR NOBODY?
  #
  # THE DEFECT THIS EXISTS FOR, measured on the operator's own labelled example
  # (look `1943e690035b`, Drew Lock, 2026-09-25). The in-model set ranked:
  #
  #   1. operator-added                (helmet)
  #   2. face 92  Drew Lock 10 22 2023.jpg   <- the right man
  #   3. face 90  Drew Hutton.jpg            <- A DIFFERENT MAN
  #
  # A clear photograph of a stranger outranks a helmeted photograph of the right
  # person, because the vision classifier was asked whether A face is visible and it
  # answers that correctly for anybody. An identity minted from that set is a blended
  # stranger, which defeats the whole feature.
  #
  # THE FREE SIGNAL WAS PRINTED ON THE TILE THE WHOLE TIME: the title literally says
  # "Drew Hutton". Reading it costs nothing, needs no network and no credential, and
  # it catches exactly this case.
  #
  # ⚠ IT IS A FILTER, NOT THE ANSWER, and this is the honest limit of the object. It
  # can only judge a title that NAMES somebody. Three shapes it cannot touch:
  #
  #   · an untitled photograph          -> :unknown, and eligible
  #   · a mis-titled photograph         -> whatever the title says, believed
  #   · a stranger sharing NO name component with our person ("Russell Wilson.jpg"
  #     returned for "Drew Lock") -> :unknown, because the evidence for :names_other
  #     is a CONFLICT with one of our person's own name words, and there is none
  #
  # The third is deliberate rather than an oversight. A title is name-shaped prose;
  # deciding "these two capitalised words are a person's name and it is not ours"
  # over arbitrary titles throws away good photographs ("Denver Broncos practice",
  # "Empower Field"), and the cost of a false positive here is a photograph of the
  # RIGHT person discarded. So the rule fires only on the shape we measured: a
  # search for a person returns a near-miss that shares one of their name words.
  module PersonNaming
    NAMES_PERSON = :names_person
    NAMES_OTHER = :names_other
    UNKNOWN = :unknown

    # WHAT THE CALLER GETS BACK. `other_name` is the conflicting name we actually
    # read, because the page has to be able to SAY why a photograph was rejected —
    # "the title names Drew Hutton" is arguable, "wrong person" is an assertion the
    # operator has to take on faith.
    Verdict = Struct.new(:kind, :other_name, keyword_init: true) do
      def names_person? = kind == NAMES_PERSON
      def names_other? = kind == NAMES_OTHER
      def unknown? = kind == UNKNOWN
    end

    # A NEIGHBOUR THAT IS CAPITALISED BUT IS NOT A PERSON'S NAME. Wikimedia titles
    # are date-heavy ("Drew Lock, 22 October 2023"), and a month sitting next to a
    # name word must not read as a surname. Kept SHORT on purpose: every word added
    # here is a word that can no longer be recognised as a stranger's name, so the
    # list holds only tokens that are never surnames.
    NOT_NAMES = %w[
      january february march april may june july august september october november
      december jpg jpeg png gif webp tif tiff svg file image photo photograph
    ].freeze

    # A WORD SHORT ENOUGH TO BE AN INITIAL IS NOT A SURNAME. "Drew L." and "Lock, D."
    # carry no second person, and treating a single letter as one would reject the
    # right man's photograph on the strength of his own initial.
    MIN_NAME_WORD = 2

    def self.judge(title, person_name)
      components = words(person_name)
      return Verdict.new(kind: UNKNOWN) if components.empty?

      title_words = words(title)
      return Verdict.new(kind: UNKNOWN) if title_words.empty?

      # OUR PERSON'S WHOLE NAME WINS OUTRIGHT, and it is tested FIRST. "Drew Lock and
      # Drew Hutton" names a stranger AND our man; the photograph is of our man too,
      # so the naming check must not throw it away. Whether it holds two faces is a
      # different question, and Appearances::FaceVisibility answers that one.
      return Verdict.new(kind: NAMES_PERSON) if components.all? { |word| title_words.include?(word) }

      other = conflicting_name(title, title_words, components)
      return Verdict.new(kind: NAMES_OTHER, other_name: other) if other

      Verdict.new(kind: UNKNOWN)
    end

    def self.names_person?(title, person_name) = judge(title, person_name).names_person?

    # A NAME WORD OF OURS WITH A STRANGER'S NAME WORD BESIDE IT.
    #
    # Both neighbours are examined because captions run in both orders — "Drew
    # Hutton" and "Hutton, Drew" are the same claim about the same man.
    def self.conflicting_name(title, title_words, components)
      capitals = capitalised(title)

      title_words.each_with_index do |word, index|
        next unless components.include?(word)

        [index - 1, index + 1].each do |neighbour_index|
          next if neighbour_index.negative?

          neighbour = title_words[neighbour_index]
          next if neighbour.nil? || components.include?(neighbour)
          next unless name_shaped?(neighbour, capitals)

          return restore_case(neighbour, title)
        end
      end

      nil
    end

    # A STRANGER'S NAME IS CAPITALISED IN THE TITLE THE PROVIDER GAVE US.
    #
    # THE CAPITAL IS THE WHOLE DISCRIMINATOR, and it is why this is not a stop-word
    # list: "Drew at Broncos practice" has a lowercase `at` beside the name word and
    # is not a second person, while "Drew Hutton" has a capital and is. A stop list
    # would have had to enumerate every English word that can follow a first name.
    def self.name_shaped?(word, capitals)
      word.length >= MIN_NAME_WORD && !NOT_NAMES.include?(word) && capitals.include?(word)
    end

    # THE WORDS OF A TITLE, WITH THE FILENAME PUNCTUATION TAKEN OFF. Commons hands us
    # "Drew_Hutton.jpg" and "Drew Lock, 22 October 2023" for the same kind of fact, so
    # underscores, dots and commas are separators rather than characters.
    #
    # DIGITS ARE DROPPED ENTIRELY. A date is never a name, and keeping "2023" as a
    # word would let it sit beside a name word as a candidate stranger.
    def self.words(text)
      text.to_s.downcase.gsub(/[^a-zÀ-ɏ']+/i, " ").split.reject { |w| w.length < MIN_NAME_WORD }
    end

    # THE TITLE'S OWN CAPITALISED WORDS, downcased for comparison. Read from the
    # ORIGINAL string, because `words` has already lost the case that matters.
    def self.capitalised(text)
      text.to_s.scan(/\b[[:upper:]][[:alpha:]']*/).map(&:downcase)
    end

    # THE STRANGER'S NAME AS THE PROVIDER WROTE IT, for the page. Falls back to the
    # normalised word when the original cannot be found, which cannot happen for a
    # word we matched case-insensitively but is cheaper than proving it cannot.
    def self.restore_case(word, title)
      title.to_s[/\b#{Regexp.escape(word)}\b/i] || word
    end

    private_class_method :conflicting_name, :name_shaped?, :capitalised, :restore_case
  end
end
