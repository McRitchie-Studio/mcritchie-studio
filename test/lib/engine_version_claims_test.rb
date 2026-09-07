# frozen_string_literal: true

# [unit] The review-hop floor is taught in five files. None of them may pair a
# REPO NAME with a studio-engine VERSION as a statement of current fact.
#
# ---------------------------------------------------------------------------
# THE DEFECT (measured 2026-09-07, and this is its third sitting).
#
# One sentence — "the hub is on 0.38.0 and turf-monster is on 0.31.0" — was
# written once into docs/agents/modules/building-sop.md and copied, in spirit or
# verbatim, into four more places. Both apps' Gemfile.locks resolved 0.70.0 when
# this test was written: 39 minors past the version quoted, and 34 past the
# 0.36.0 floor the sentence existed to help you apply. Every copy was false, and
# each one recommended `--email` — the sub-floor deviation — for apps that have
# not needed it in a long time.
#
# A previous task deleted the sentence from the doc alone. The reviewers of that
# PR found it alive in three more files, and worse: the doc's replacement prose
# pointed the reader AT one of them as the authority on the threshold. The defect
# had been relocated behind a fresh pointer rather than removed.
#
# WHY A TEST AND NOT JUST THE EDIT. This family regenerates. The sentence is
# helpful-looking — a reader mid-task genuinely wants to know which apps are
# sub-floor — so the next person to touch these files has every reason to write
# it again, and nothing would fail. Deleting the fifth copy by hand buys one
# sitting; asserting the property is what ends it.
#
# THE RULE, stated at bin/lib/client_surface_diff.rb ("Name the condition, not
# the repo"): the FLOOR is a live rule and must stay written down. WHICH apps
# sit below it is a fact about two lockfiles on one day, and belongs nowhere but
# a lockfile. `grep -m1 'studio-engine (' Gemfile.lock` is the authority.
# ---------------------------------------------------------------------------

require "bundler/setup"
require "minitest/autorun"

class EngineVersionClaimsTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # The five files that teach the review-hop engine floor. This is the blast
  # radius of the original sentence, not an arbitrary sample: each one was found
  # carrying a copy, or (the doc) pointing at one that did.
  SCANNED = %w[
    bin/verify-review-hop
    bin/lib/review_hop.rb
    test/lib/review_hop_test.rb
    test/commands/verify_review_hop_test.rb
    docs/agents/modules/building-sop.md
  ].freeze

  # Every app that resolves studio-engine, plus "the hub", which is how these
  # files spell mcritchie-studio in prose. Listed rather than derived because the
  # thing being banned IS the name: a derived list would need a source of truth
  # naming them, which is the artefact under suspicion.
  APP_NAMES = [
    /\bturf[-_ ]monster\b/i,
    /\bmcritchie[-_ ]studio\b/i,
    /\brolio\b/i,
    /\bchain[-_ ]ops\b/i,
    /\bthe hub\b/i
  ].freeze

  # A studio-engine version: two or three dotted numbers. Deliberately loose —
  # the defect is the PAIRING, and a version written "0.31" rots exactly as fast
  # as one written "0.31.0" (engine_pin_contract_test.rb records a real instance
  # of the short spelling being believed).
  VERSION = /(?<!\d)\d+\.\d+(?:\.\d+)?(?!\d)/

  # A sentence stating measured history is NOT the defect, and banning it would
  # cost the files their record of what went wrong. The marker must be explicit:
  # an ISO date, or a word that puts the claim in the past.
  HISTORY_MARKER = /
    \b20\d\d-\d\d-\d\d\b        # an ISO date stamps the measurement
    | \bmeasured\b
    | \bused\ to\b
    | \bwent\ stale\b
    | \brotted?\b
    | \bre-read\b
    | \bhistory\b
  /xi

  def read(rel) = File.read(File.join(ROOT, rel))

  # Split into sentences so the marker has to sit WITH the claim it excuses. A
  # whole-file check would let one "measured 2026-09-07" anywhere in a 380-line
  # document license every pairing in it.
  def sentences(text)
    text.gsub(/\s+/, " ").split(/(?<=[.!?])\s+/)
  end

  # The detector, factored out so the control tests below can aim it at strings
  # whose verdict is known. A source scan that is only ever pointed at the tree
  # it is meant to bless can pass by reading nothing at all.
  def pairings(text)
    sentences(text).select do |sentence|
      APP_NAMES.any? { |app| sentence.match?(app) } &&
        sentence.match?(VERSION) &&
        !sentence.match?(HISTORY_MARKER)
    end
  end

  # ── 1. ANTI-VACUITY: the scan reaches real files with real content ──────────
  #
  # THE FAILURE THIS EXISTS FOR. A scanning test whose glob resolves to nothing,
  # or whose paths moved, asserts `assert_empty []` and reports green forever. It
  # would have gone green on the defect it was written to catch. So the inputs
  # are asserted before anything is concluded from them.
  def test_every_scanned_file_exists_and_was_actually_read
    SCANNED.each do |rel|
      path = File.join(ROOT, rel)

      assert File.exist?(path), "#{rel} is in SCANNED but does not exist — the scan below " \
                                "would silently cover one file fewer. Fix the path or drop it."

      content = read(rel)
      refute_empty content.strip, "#{rel} read as empty; the scan would pass vacuously"
      assert_operator content.length, :>, 400,
                      "#{rel} is #{content.length} bytes — too short to be the file this test " \
                      "means to scan. A truncated or stubbed read passes every check below."
    end
  end

  # ── 2. ANTI-VACUITY: the detector actually bites on the REAL defect text ────
  #
  # The sharpest control available: the exact sentence this whole family came
  # from. If the detector cannot flag the string that caused three tasks, it
  # cannot defend the tree, however green it is.
  def test_the_detector_flags_the_original_defect_sentence
    original = "As of 2026-08-11 the hub is on 0.38.0 and turf-monster is on 0.31.0 — so on " \
               "turf-monster today this is the sub-floor path."

    # The date is stripped: an ISO stamp excuses a sentence that reads as history,
    # and this one does not — it says "today". The control is the PAIRING.
    undated = original.sub("As of 2026-08-11 ", "")

    refute_empty pairings(undated),
                 "the detector did not flag the sentence this test exists because of: " \
                 "#{undated.inspect}. Every assertion below is worthless until it does."
  end

  # Named repo + version with no history marker is the defect, in either spelling.
  def test_the_detector_flags_a_bare_pairing_in_both_version_spellings
    ["turf-monster is on 0.31.0.", "turf-monster is on 0.31.", "the hub runs studio-engine 0.38.0."]
      .each do |bad|
        refute_empty pairings(bad), "#{bad.inspect} is a repo-version pairing and must be flagged"
      end
  end

  # ── 3. ANTI-VACUITY, THE OTHER DIRECTION: the detector is not a blanket ban ──
  #
  # A detector that flags everything is as useless as one that flags nothing, and
  # it fails LOUDLY in the opposite way: it would force the files to delete the
  # floor itself, which is the live rule. These are the shapes that must survive.
  def test_the_detector_permits_the_floor_and_dated_history
    [
      "ONLY for apps on studio-engine < 0.36.0, which has no reviewer fallback.",
      "Below 0.36.0 there is no reviewer fallback and no provisioning.",
      "Measured 2026-09-07, both apps it named resolved studio-engine 0.70.0.",
      "A version snapshot used to stand here, naming the hub at 0.38.0."
    ].each do |good|
      assert_empty pairings(good),
                   "#{good.inspect} states the floor or dated history, not a current pairing — " \
                   "flagging it would push these files to delete the live rule"
    end
  end

  # ── 4. THE PROPERTY ─────────────────────────────────────────────────────────
  def test_no_scanned_file_pairs_a_repo_with_an_engine_version_as_current_fact
    offences = SCANNED.flat_map { |rel| pairings(read(rel)).map { |s| "#{rel}: #{s}" } }

    assert_empty offences,
                 "these sentences pair a REPO with a studio-engine VERSION as current fact:\n" \
                 "#{offences.join("\n")}\n\n" \
                 "Both apps resolved 0.70.0 when this test was written, so the last such " \
                 "sentence was 39 minors wrong. Name the CONDITION (the 0.36.0 floor, or the " \
                 "MISSING_EMAIL the mint returns), not the repo. If the sentence really is a " \
                 "record of something measured, date it."
  end

  # ── 5. THE FLOOR MUST SURVIVE ───────────────────────────────────────────────
  #
  # The failure mode of fix #4 is over-correction: deleting the threshold along
  # with the repo names, leaving a reader who cannot apply the rule at all. The
  # doc says the MISSING_EMAIL failure text is the surface to trust "because it
  # is the one a test asserts" — this is that test, so that sentence stays true.
  def test_the_live_floor_is_still_written_where_the_doc_sends_the_reader
    assert_match(/0\.36\.0/, read("bin/verify-review-hop"),
                 "the --email help must keep naming the threshold; the doc points here for it")
    assert_match(/0\.36\.0/, read("bin/lib/review_hop.rb"),
                 "the MISSING_EMAIL failure text must keep naming the floor — the doc calls it " \
                 "the surface to trust BECAUSE a test asserts it, and this is that test")
  end
end
