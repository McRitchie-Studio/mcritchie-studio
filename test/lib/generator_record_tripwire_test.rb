require "test_helper"

# [unit] THE GENERATOR RECORD CANNOT QUIETLY GO BACK TO BEING FALSE.
#
# WHY A TRIPWIRE AND NOT A PROSE FIX. The eight defects this file guards were all
# comment falsehoods, and a comment fix protects nothing: the next edit can reintroduce
# any of them and CI stays green, because no runner has ever read a comment. Every claim
# below was TRUE PROSE AT THE MOMENT IT WAS WRITTEN and rotted afterwards, which is the
# only kind of falsehood worth automating against — nobody typed them in bad faith, and
# nobody will next time either. So the record is pinned where a runner can see it.
#
# `config/image_generators.yml`'s header states the rule these enforce: A ROW RECORDS
# WHAT WAS MEASURED FOR THAT ROW, AND NOTHING ELSE.
#
# HOW THE MATCHING WORKS, and it is the part to read before adding a rule.
#
# Every scanned file is FLATTENED first (#flat): comment markers stripped, all runs of
# whitespace collapsed to one space. A claim in a wrapped comment is one string again,
# so rules are plain substring checks rather than regexes that have to guess where the
# author's line broke. Two details in `#flat` are load-bearing:
#
#   * The comment-marker pattern anchors with `\s*`, NEVER `\s+`. A column-0 `#` has no
#     leading whitespace, and `\s+` would stop seeing exactly the comments in this
#     repo's YAML and its top-of-file Ruby banners.
#   * Collapsing whitespace is what makes a phrase survive a re-wrap. Pin a phrase with
#     a literal newline in it and the guard dies the first time somebody reflows the
#     paragraph — which looks like the guard working and is not.
#
# ⚠ A RULE THAT QUOTES THE CLAIM IT FORBIDS DISARMS ITSELF. A correction that says
# `this used to say "X"` puts X back in the file, and an absence check then fires on the
# correction. So the corrected comments in this change DESCRIBE the old wording instead
# of quoting it, and any future correction must do the same. If you find yourself
# needing to quote a forbidden phrase, use a SCOPED rule (see the five-references case)
# rather than weakening the absence check.
class GeneratorRecordTripwireTest < ActiveSupport::TestCase
  # The files that carry the generator record. A claim about a generator belongs to one
  # of these, and every rule below scans a named subset rather than the whole repo, so a
  # failure names a file somebody owns.
  REGISTRY_YAML = "config/image_generators.yml".freeze
  REGISTRY_RB = "app/models/image_generation/registry.rb".freeze
  CONTROLLER = "app/controllers/appearances_controller.rb".freeze
  ADAPTER = "app/services/image_generation/open_ai.rb".freeze
  USE_CASE = "app/services/appearances/generate_artifact.rb".freeze
  REFERENCE_SET = "app/services/appearances/reference_set.rb".freeze
  LOOK_READING = "app/services/appearances/look_reading.rb".freeze
  PROMPT = "app/services/appearances/character_sheet_prompt.rb".freeze
  ARTIFACT = "app/models/artifact.rb".freeze
  OUTPUT_PANEL = "app/views/appearances/_output_panel.html.erb".freeze
  REGISTRY_TEST = "test/models/image_generation/registry_test.rb".freeze
  LOOK_READING_TEST = "test/services/appearances/look_reading_test.rb".freeze
  PIPELINE_DOC = "docs/topics/content-pipeline.md".freeze

  SCANNED = [
    REGISTRY_YAML, REGISTRY_RB, CONTROLLER, ADAPTER, USE_CASE, REFERENCE_SET,
    LOOK_READING, PROMPT, ARTIFACT, OUTPUT_PANEL, REGISTRY_TEST, LOOK_READING_TEST,
    PIPELINE_DOC
  ].freeze

  EDITS_ENDPOINT = "/v1/images/edits".freeze

  # The claim, and the window (in flattened characters) within which its scope must be
  # named. 400 is about a comment paragraph: wide enough that the endpoint may be in an
  # adjacent sentence, narrow enough that a mention three paragraphs away does not
  # launder an unscoped claim.
  SCOPE_WINDOW = 400

  class << self
    def read(rel)
      Rails.root.join(rel).read
    end

    # Comment markers out, whitespace collapsed. See the header for why `\s*`.
    def flat(rel)
      read(rel)
        .gsub(/<%#/, " ")
        .gsub(/%>/, " ")
        .gsub(/^\s*#+/, " ")
        .gsub(/\s+/, " ")
    end

    # Comment prose only, one entry per sentence, punctuation and case discarded so a
    # re-wrap or a capitalisation change cannot hide a paste.
    def comment_sentences(rel)
      read(rel)
        .each_line
        .filter_map { |line| line[/^\s*#+\s?(.*)$/, 1] }
        .join(" ")
        .split(/(?<=\.) /)
        .map { |s| s.downcase.gsub(/[^a-z0-9 ]/, " ").squeeze(" ").strip }
        .reject { |s| s.length < 40 }
    end

    # The shipped defect differed by TWO WORDS, so exact equality would have missed it.
    # Compare the leading 80% of the shorter sentence: a paste-then-tweak keeps its
    # opening, which is what makes the two read as one emphatic repetition.
    def near_duplicate?(first, second)
      shorter, longer = [first, second].sort_by(&:length)
      prefix = shorter[0, (shorter.length * 0.8).to_i]
      prefix.length >= 32 && longer.start_with?(prefix)
    end

    # ⚠ A WINDOW, NOT ADJACENCY, AND THAT IS THE WHOLE CORRECTION.
    #
    # The first version of this rule compared each sentence with its immediate NEIGHBOUR
    # and did not catch the defect it was written for. What shipped was a TWO-SENTENCE
    # BLOCK pasted twice, so the repeated opening sentences were separated by the second
    # sentence of the first copy and were never neighbours. Measured by re-introducing
    # the real defect, 2026-09-27: the adjacent-only detector stayed GREEN on it.
    #
    # WINDOW is how many sentences ahead to look. 4 covers a pasted block of up to four
    # sentences, which is larger than any comment paragraph in this controller.
    WINDOW = 4

    def duplicate_pairs(sentences)
      pairs = []
      sentences.each_with_index do |sentence, i|
        (1..WINDOW).each do |ahead|
          other = sentences[i + ahead]
          next if other.nil?

          pairs << [sentence, other] if near_duplicate?(sentence, other)
        end
      end
      pairs
    end
  end

  def flat(rel) = self.class.flat(rel)

  # ── The guard is inspecting real files ─────────────────────────────────────────
  #
  # FIRST, BECAUSE EVERY OTHER TEST HERE PASSES VACUOUSLY ON A MISSING FILE. An absence
  # check against a file that was renamed reports absence and means nothing. A rename
  # must break this test loudly rather than silently disarm the other nine.
  test "every scanned file exists and has content" do
    SCANNED.each do |rel|
      path = Rails.root.join(rel)

      assert_path_exists path, "#{rel} is scanned by this guard and is not there — if it moved, " \
                               "update the constant; the absence checks below are vacuous without it"
      assert_operator path.size, :>, 200, "#{rel} is suspiciously small to be carrying the record"
    end
  end

  test "flattening actually joins a claim that wraps across comment lines" do
    # The registry row's arity note wraps; flattened, it is one searchable sentence.
    assert_includes flat(REGISTRY_YAML), "QUALITY BELIEF, NOT AN API LIMIT",
                    "if this fails, #flat stopped stripping YAML comment markers and every " \
                    "phrase rule below is matching raw source with newlines in it"
    assert_not_includes flat(REGISTRY_YAML), "\n", "flattening must leave no newlines"
  end

  # ── 1. The withdrawn overclaims stay withdrawn, in PROSE ───────────────────────
  #
  # registry_test.rb already asserts they are absent from the DATA. This is the other
  # half: the comment that contradicted that test for two weeks. The repo asserted a
  # fact in a test and denied it in a comment, in the very file whose header exists to
  # enforce truth-of-record.
  test "no comment claims the registry leads with a row claiming withdrawn capabilities" do
    %w[full_body back_view expressions].each do |withdrawn|
      [REGISTRY_RB, REGISTRY_YAML, CONTROLLER, USE_CASE].each do |rel|
        assert_not_includes flat(rel), "the row that claims #{withdrawn}",
                            "#{rel} credits a row with #{withdrawn}; no row claims it and " \
                            "registry_test.rb asserts so"
      end
    end

    assert_not_includes flat(REGISTRY_RB), "leads with the row that claims",
                        "the .for order comment is crediting the lead row with a capability again"
  end

  # ── 2. The token cost is an ORDER or a RANGE, never one sample ──────────────────
  #
  # The invented figure came from a TEST STUB (appearances_generate_test.rb) and was
  # quoted in five places as an observed OpenAI cost. Three real sheets measured
  # 6,724-7,629, which is not tens of thousands and is not any single number either.
  FABRICATED_ORDERS = ["tens of thousands of TOKENS", "tens of thousands of tokens"].freeze
  FABRICATED_FIGURES = %w[18432 18,432 18_432 18,000].freeze

  test "no file claims the OpenAI token cost is tens of thousands" do
    FABRICATED_ORDERS.each do |claim|
      SCANNED.each do |rel|
        assert_not_includes flat(rel), claim,
                            "#{rel} overstates the measured token cost by an order of magnitude " \
                            "(measured 6,724-7,629 — see #{REGISTRY_YAML})"
      end
    end
  end

  test "no file illustrates the token cost with a figure nothing measured" do
    FABRICATED_FIGURES.each do |figure|
      SCANNED.each do |rel|
        assert_not_includes flat(rel), figure,
                            "#{rel} quotes #{figure} as a token count; no measurement supports it. " \
                            "Cite the range or the order, never a sample — see #{REGISTRY_YAML}"
      end
    end
  end

  # THE POSITIVE HALF. Absence checks alone would pass on a file that said nothing at
  # all, so the row must still carry the measured evidence the rules above defer to.
  # EACH SAMPLE IS KEYED TO ITS SUBJECT, not asserted as a bare number. A bare `6724`
  # is also a substring of the RANGE `6724-7629`, so deleting the jaylen-waddle sample
  # left the check green — the assertion could not tell a listed sample from a digit of
  # the range. Measured by mutation, 2026-09-27. The subject is what makes a sample
  # re-checkable by somebody else, so it is the right thing to require.
  MEASURED_SHEETS = { "7629" => "Courtland Sutton", "7423" => "bo-nix", "6724" => "jaylen-waddle" }.freeze

  test "the registry row records the measured range and every sheet behind it" do
    row = ImageGeneration::Registry.find!("openai_gpt5_sheet")
    cost = row.measured[:cost].to_s

    MEASURED_SHEETS.each do |tokens, subject|
      assert_match(/#{tokens}\s*\(#{Regexp.escape(subject)}/, cost,
                   "the row must carry the #{subject} sheet's #{tokens} tokens as a LABELLED " \
                   "sample — three sheets are what makes the range a range")
    end
    assert_operator MEASURED_SHEETS.size, :>=, 3,
                    "fewer than three samples cannot support a range claim"
    assert_match(/6724-7629|6,724-7,629/, cost, "the row must state the range, not only the samples")
  end

  # ── 3. A comment that cites a guard names the guard ─────────────────────────────
  test "the registry does not point at a guard that is not in the registry" do
    scanned = flat(REGISTRY_RB)

    assert_not_includes scanned, "see the guard below",
                        "#{REGISTRY_RB} cites a guard 'below' — the guard is in " \
                        "#{REGISTRY_TEST}, in another directory. Name the file and the test."
    assert_includes scanned, REGISTRY_TEST,
                     "the measured_on comment must name the file holding the guard it relies on"
  end

  # ── 4. The panel count says which reading it is ────────────────────────────────
  #
  # One row gave two counts with no reconciliation: ten and eight. Both are correct
  # readings of a 5x2 grid whose two full-body figures span both rows — ten CELLS, eight
  # FIGURES. The defect was leaving a reader to pick.
  test "the registry row reconciles the two panel counts rather than giving both bare" do
    scanned = flat(REGISTRY_YAML)

    assert_includes scanned, "TEN CELLS, EIGHT FIGURES",
                    "the row must say which count is which; it once gave ten in `result` and " \
                    "eight in `cost` with nothing joining them"
    assert_includes scanned, "2 full-body + 6 head views",
                    "the reconciliation has to show the arithmetic, or it is just a third claim"
  end

  # ── 5. The worked example is one the code can reach ────────────────────────────
  test "the controller does not credit the sheet panel to a fal row or its credential" do
    scanned = flat(CONTROLLER)

    assert_not_includes scanned, "set FAL_KEY to turn it on",
                        "#{CONTROLLER}'s worked example names FAL_KEY. GenerateArtifact::CAPABILITY " \
                        "is :character_sheet and no fal row claims it, so the panel cannot print this"
    assert_not_includes scanned, "Ideogram V3 Character —",
                        "the worked example names the Ideogram label, which this path cannot reach"
  end

  # ── 6. The five-references finding stays attached to its endpoint ──────────────
  #
  # SCOPED, NOT ABSENT, and deliberately so. The sentence is TRUE of
  # /v1/images/edits — that is where it was measured — so forbidding it outright would
  # delete a real finding. What it may never be is unattributed: it was at one point
  # credited to three different paths (the Responses row, the edits endpoint, and the
  # Higgsfield trainer), and three attributions of one measurement is no measurement.
  #
  # ⚠ WHAT THIS RULE CANNOT DO, stated because a reader will otherwise over-trust it. A
  # window catches an ORPHANED claim — one in a passage that never names the endpoint. It
  # does NOT catch a claim mis-scoped INSIDE a passage that names the endpoint for some
  # other reason: the sheet row's header discusses /v1/images/edits at length, so a
  # sentence there can lose its explicit subject and still sit within the window.
  # Measured by mutation, 2026-09-27 — dropping the explicit subject from that row's
  # header stayed green. The absence rules above are exact; this one is a net.
  FIVE_REF_PHRASES = [
    "no better than one",
    "measured NO BETTER than one",
    "were no better with five reference photos",
    "five references measured no better",
    "five references performed no better",
    "five performed no better"
  ].freeze

  test "every five-references claim names the endpoint it was measured on" do
    found = 0

    SCANNED.each do |rel|
      scanned = flat(rel)
      FIVE_REF_PHRASES.each do |phrase|
        offset = 0
        while (hit = scanned.index(phrase, offset))
          found += 1
          from = [hit - SCOPE_WINDOW, 0].max
          window = scanned[from...(hit + phrase.length + SCOPE_WINDOW)]

          assert_includes window, EDITS_ENDPOINT,
                          "#{rel} carries \"#{phrase}\" without #{EDITS_ENDPOINT} nearby. That " \
                          "finding was measured on the edits endpoint ONLY; attaching it to the " \
                          "Responses sheet path is the three-attribution defect coming back"
          offset = hit + 1
        end
      end
    end

    assert_operator found, :>, 0,
                    "this rule matched nothing, so it is proving nothing — the phrase list has " \
                    "drifted from how the repo actually words the claim"
  end

  # ── 7. The pads defect keeps its two measurements ──────────────────────────────
  #
  # Three files record this defect and the prompt file is the one a builder reads before
  # touching PADS_CLAUSE, so it must be the STRONGEST, not the weakest. It cited one
  # measurement and dropped "either time", which invites a builder to retry a thing that
  # was already tried twice.
  test "the prompt file records both pads measurements and that neither fix worked" do
    scanned = flat(PROMPT)

    assert_includes scanned, "MEASURED TWICE INDEPENDENTLY",
                    "#{PROMPT} must cite both measurements, like the other two recordings"
    assert_includes scanned, "EITHER TIME",
                    "dropping 'either time' reads as though per-panel repetition is untried"
    assert_includes scanned, "six_head_panels_have_pads",
                    "the observable criterion is the transferable part; keep it"
  end

  # ── 8. A pasted-twice comment does not come back ───────────────────────────────
  #
  # `generated_message`'s header shipped duplicated, differing by two words — an edit
  # artifact that reads as emphasis. Generalised to the whole controller rather than
  # pinned to that sentence, because the next paste will be a different sentence.
  # NOTE THE SHAPE: it collects, then asserts ONCE. A loop whose body only calls `flunk`
  # asserts NOTHING on the passing path, and minitest reports "Test is missing
  # assertions" — a green that proves the scan ran, not that it found nothing. Measured
  # here on the first run of this file.
  test "no comment sentence is repeated back to back in the controller" do
    sentences = self.class.comment_sentences(CONTROLLER)

    assert_operator sentences.size, :>, 10,
                    "the sentence split found almost nothing — this scan is inspecting no prose"

    repeats = self.class.duplicate_pairs(sentences)

    assert_empty repeats.map { |a, b| "#{a[0, 60]}… / #{b[0, 60]}…" },
                 "#{CONTROLLER} repeats a comment sentence back to back. The shipped defect was " \
                 "`generated_message`'s header pasted twice, differing by two words, which reads " \
                 "as deliberate emphasis rather than as the edit artifact it is."
  end

  # ── 9. The doc's rejection-reason list matches the shipped constant ────────────
  #
  # THE ONLY RULE HERE THAT IS NOT A PHRASE CHECK, and the most valuable, because it
  # cannot rot: it compares the doc against the code every time it runs. The doc named
  # three reasons and the constant had grown to ten — it went stale by SEVEN without a
  # single test noticing, which is what a prose-only record always eventually does.
  # THE LIST IS READ FROM A DELIMITED BLOCK, NOT FROM THE WHOLE DOC, and that is the
  # second version of this rule. The first scanned the entire file for `` `reason` ``
  # and it let a deletion through: the paragraph introducing the list mentioned three
  # reason names in passing, so removing one from the LIST still left it present in the
  # FILE and the check passed. A whole-file search cannot tell a list entry from a
  # mention. Measured by mutation, 2026-09-27.
  REASONS_BEGIN = "<!-- REJECTION_REASONS:BEGIN".freeze
  REASONS_END = "<!-- REJECTION_REASONS:END -->".freeze

  test "the pipeline doc enumerates exactly the shipped rejection reasons" do
    reasons = AppearanceReferencePhoto::REJECTION_REASONS
    doc = self.class.read(PIPELINE_DOC)

    # BOTH markers, checked separately. A slice taken on a half-present pair silently
    # runs to the end of the file (or returns nothing) and the comparison becomes noise.
    assert_includes doc, REASONS_BEGIN, "#{PIPELINE_DOC} lost the rejection-reason BEGIN marker"
    assert_includes doc, REASONS_END, "#{PIPELINE_DOC} lost the rejection-reason END marker"

    block = doc[/#{Regexp.escape(REASONS_BEGIN)}.*?-->(.*?)#{Regexp.escape(REASONS_END)}/m, 1].to_s
    listed = block.scan(/`([a-z_]+)`/).flatten

    refute_empty listed, "the delimited block parsed to no reasons — the guard is comparing nothing"
    assert_equal reasons.sort, listed.sort,
                 "#{PIPELINE_DOC}'s rejection-reason block and " \
                 "AppearanceReferencePhoto::REJECTION_REASONS disagree.\n" \
                 "  only in the constant: #{(reasons - listed).inspect}\n" \
                 "  only in the doc:      #{(listed - reasons).inspect}\n" \
                 "The constant is the truth; the doc is what an operator reads."
    assert_equal listed, listed.uniq, "the doc lists a reason twice"
  end

  # ── 10. The arity decision stays stated rather than silently flipped ───────────
  #
  # `reference_arity: one` on the sheet row is a QUALITY BELIEF, not an API shape, and it
  # is unmeasured. The adapter is wired for the plural answer, so flipping it is one word
  # — which is exactly why the row has to carry the reasoning and what would settle it.
  test "the sheet row's reference arity carries its reasoning and its exit condition" do
    scanned = flat(REGISTRY_YAML)
    row = ImageGeneration::Registry.find!("openai_gpt5_sheet")

    assert_equal "one", row.reference_arity,
                 "the row was flipped to many — that is a measurable claim, so the measurement " \
                 "belongs in measured: and this guard's WHAT WOULD SETTLE IT note should go"
    assert_includes scanned, "WHAT WOULD SETTLE IT",
                    "an unmeasured belief must say what evidence would retire it, or it is a guess " \
                    "that outlives everyone who remembers it was a guess"
    assert_includes scanned, "NOT FLIPPED TO `many`, DELIBERATELY",
                    "the decision must be stated; silence reads as nobody having considered it"
  end
end
