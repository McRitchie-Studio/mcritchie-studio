module Athletes
  # A NAME, REDUCED TO WHAT IS THE SAME ABOUT TWO SPELLINGS OF ONE MAN.
  #
  # ── THE MEASUREMENT THAT PUT THIS HERE ───────────────────────────────────────
  #
  # Measured 2026-09-27 against the development database, walking ESPN's Las Vegas
  # roster (79 players) and asking Person.find_by_name for each: 18 came back with
  # no person. One of the 18 was a LIE.
  #
  #     Person.find_by_name("AJ", "Cole")    -> nil
  #     Person.find_by_name("A.J.", "Cole")  -> "a-j-cole"     # he is on file
  #
  # Person.find_by_name strips periods from the name it is HANDED and then looks up
  # a slug, so it can find "A.J. Cole" when asked for "A.J. Cole" — but the stored
  # slug is already `a-j-cole`, and ESPN says "AJ Cole", which parameterizes to
  # `aj-cole`. Neither spelling reaches the other.
  #
  # The consequence is the worst thing an acquire act can do: it would have decided
  # a punter we have had for years is a new signing, created a SECOND Person for
  # him, and left two records for one human — the exact split
  # `nfl:merge_duplicate_athletes` exists to clean up after. So an acquire is not
  # allowed to run on "find_by_name returned nil" alone. It has to ask this object
  # whether anyone on file could be the same man, and REFUSE when the answer is
  # maybe.
  #
  # ── WHAT IT NORMALIZES, AND WHY SUFFIXES GO ──────────────────────────────────
  #
  # Downcased, stripped of everything that is not a letter or a digit, and stripped
  # of a trailing generational suffix. ESPN carries the suffix inside `lastName`
  # (measured: "Washington Jr.", "Zuhn III"), and this repo's own history says the
  # suffix is exactly where records split — `Athletes::MergeDuplicates` was written
  # for "Will Anderson" sitting beside "Will Anderson Jr.".
  #
  #     "A.J. Cole"           -> "ajcole"
  #     "AJ Cole"             -> "ajcole"
  #     "Mike Washington Jr." -> "mikewashington"
  #     "Trey Zuhn III"       -> "treyzuhn"
  #
  # ── IT IS A REFUSAL KEY, NOT A MERGE KEY ─────────────────────────────────────
  #
  # Collapsing the suffix deliberately makes "Robert Griffin" and "Robert Griffin
  # III" one key, and those are sometimes two people. That is correct for the only
  # thing this key is used for: a near match makes the act STOP and name the
  # candidate for a human to settle. It must never be used to pick a row to write
  # to — identity is decided by `espn_id`, and by nothing else.
  module NameKey
    SUFFIXES = %w[jr jr. sr sr. ii iii iv v].freeze

    # The comparable key for a full name, or "" when there is nothing to compare.
    def self.for(name)
      tokens = name.to_s.downcase.split(/\s+/)
      tokens.pop while tokens.length > 1 && SUFFIXES.include?(tokens.last)
      tokens.join.gsub(/[^a-z0-9]/, "")
    end

    def self.for_parts(first, last) = self.for("#{first} #{last}")

    # PEOPLE WHO MIGHT BE THIS NAME SPELLED DIFFERENTLY. Deliberately excludes
    # nobody: a caller that already found an exact match does not ask.
    #
    # Two steps because one of them cannot be indexed. The SQL narrows on a
    # punctuation-stripped last name so the scan is over a handful of rows, then
    # Ruby compares the whole key. A functional index would make the first step
    # exact, and is not worth a migration against 3,056 people for an act that runs
    # once per player — measured cost of the widened scan is a few milliseconds.
    def self.near_matches(name)
      key = self.for(name)
      return Person.none if key.empty?

      bare_last = bare_last_name(name)
      return Person.none if bare_last.empty?

      candidates = Person.where(
        "regexp_replace(lower(last_name), '[^a-z0-9]', '', 'g') LIKE ?", "#{bare_last}%"
      )
      candidates.select { |person| self.for(person.full_name) == key }
    end

    # The last name with its suffix and punctuation gone — the narrowing term for
    # the query above. "Washington Jr." -> "washington".
    def self.bare_last_name(name)
      tokens = name.to_s.downcase.split(/\s+/)
      tokens.pop while tokens.length > 1 && SUFFIXES.include?(tokens.last)
      tokens.last.to_s.gsub(/[^a-z0-9]/, "")
    end
  end
end
