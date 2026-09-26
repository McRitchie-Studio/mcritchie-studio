module Appearances
  # THE FREE SCORE — metadata only, no network, no spend.
  #
  # IT HAS ONE HONEST JOB AND IT IS NOT THE OPERATOR'S: deciding which candidates
  # are worth PAYING to look at. Appearances::FaceVisibility bills per image, so
  # something has to shortlist, and something has to rank when that classifier is
  # unavailable. This is that something.
  #
  # ⚠ IT CANNOT SOLVE THE PROBLEM IT SHORTLISTS FOR, and saying so here is the
  # point of this comment. Measured on the operator's own labelled example (look
  # `1943e690035b`, Drew Lock):
  #
  #   hit 1  556x780   ar 0.71  "Drew Lock, 22 October 2023"   BARE FACE
  #   hit 2  686x930   ar 0.74  "Drew Lock, 18 December 2023"  HELMET
  #
  # Same shape, same title pattern, same source, opposite answer. NO metadata
  # signal available to us orders that pair correctly, so a reader must not read a
  # high merit score as "this photograph shows a face" — it means "this is worth a
  # closer look". The closer look costs money and lives in FaceVisibility.
  #
  # WHAT IT CAN DO is throw out the things that are obviously not photographs of a
  # person — scanned book pages, media-guide PDFs, diagrams — which on a real
  # search are a large fraction of the answer (measured on Wikimedia Commons:
  # 12 of 20 results for "Drew Lock" are documents, not photographs). Every one of
  # those it catches is an image we do not pay to classify.
  module PhotoMerit
    # A SCANNED PAGE IS NOT A PHOTOGRAPH OF ANYONE. Matched on the URL rather than
    # only the title because a provider may give us neither a title nor a page —
    # the rendered thumbnail path keeps the source extension either way
    # (`.../page1-500px-1976_Penn_State...pdf.jpg`).
    DOCUMENT_MARKERS = %w[.pdf .djvu .tif .eps .svg page1- /page].freeze

    # PORTRAIT-ISH IS MILDLY GOOD, WIDE IS MILDLY BAD. A face fills more of a tall
    # frame than of a 3:2 crowd shot, and the widest candidate in the labelled
    # example (3207x2135, ar 1.50) is a distant sideline photograph. "Mildly" is
    # the operative word — see the header for why this can never be decisive.
    PORTRAIT_RANGE = (0.55..1.15)
    WIDE_RATIO = 1.5

    # A photograph too small to carry a face is not worth classifying. Below this
    # on the long edge it is a thumbnail or an icon.
    MIN_USEFUL_EDGE = 300

    # Returns 0.0..1.0. Never raises: this runs over whatever a provider handed us,
    # including rows with no dimensions and no title at all.
    def self.score(result, person_name: nil)
      return 0.0 if document?(result)

      score = 0.5
      score += 0.2 if names_person?(result, person_name)
      score += 0.15 if portrait?(result)
      score -= 0.2 if wide?(result)
      score -= 0.3 if too_small?(result)
      # The provider's own relevance is a real signal and the only one that
      # survives when a result carries no metadata at all: hit 1 beats hit 18.
      score += rank_bonus(result)

      score.clamp(0.0, 1.0)
    end

    def self.document?(result)
      haystack = "#{result.image_url} #{result.page_url} #{result.title}".downcase
      DOCUMENT_MARKERS.any? { |marker| haystack.include?(marker) }
    end

    def self.names_person?(result, person_name)
      return false if person_name.blank?

      title = result.title.to_s.downcase
      return false if title.empty?

      # Every word of the name, so "Drew Hutton" does not match "Drew Lock" —
      # measured as a real neighbour in a Commons answer for that very query.
      person_name.to_s.downcase.split.all? { |word| title.include?(word) }
    end

    def self.portrait?(result)
      ratio = aspect(result)
      ratio.present? && PORTRAIT_RANGE.cover?(ratio)
    end

    def self.wide?(result)
      ratio = aspect(result)
      ratio.present? && ratio >= WIDE_RATIO
    end

    def self.too_small?(result)
      longest = [result.width, result.height].compact.max
      longest.present? && longest < MIN_USEFUL_EDGE
    end

    def self.aspect(result)
      width = result.width
      height = result.height
      return nil if width.blank? || height.blank? || height.to_i.zero?

      width.to_f / height.to_f
    end

    # Decays across the first ten hits and then stops mattering. Deliberately
    # small: it is a tie-breaker among candidates the other signals could not
    # separate, not a re-statement of the provider's ordering.
    def self.rank_bonus(result)
      position = result.position.to_i
      return 0.0 unless position.positive?

      (0.1 * (1.0 - ([position, 10].min - 1) / 10.0)).round(4)
    end

    private_class_method :aspect
  end
end
