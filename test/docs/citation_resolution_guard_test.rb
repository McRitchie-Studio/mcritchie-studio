# frozen_string_literal: true

require "test_helper"

# A LINE NUMBER IS TRUE ONLY AT THE SHA IT WAS WRITTEN AGAINST.
#
# Found 2026-09-14 across three reviews in one day. Eight `bin/release.rb:<line>`
# citations elsewhere in this repo were spot-checked after one ordinary commit
# shifted that file; ALL EIGHT were already pointing at unrelated lines, one at a
# blank line. Two more sat in the same table cell of the QA-release SOP as the
# sentence announcing the cite-the-seam discipline. A third review
# found a dead pointer inside the very change whose thesis was dead pointers.
#
# 8/8 is not carelessness. It is a format with no feedback loop: every commit to a
# cited file silently rots every citation below its edit point, and nothing re-reads
# one. A rotted citation does not look rotted — it reads exactly like the truth, and
# routes a reader to whatever happens to sit at that offset today.
#
# WHAT THIS GUARD DOES, in three lanes. Each asks only "does this RESOLVE?" — it
# opens the cited file and looks. None of them reads the prose around the citation,
# which is the whole design: a guard keyed on WORDING is evaded by rephrasing, and a
# sibling guard keyed on VERBS was measured against twelve of them by its reviewer,
# slipping on plurals, noun forms, participles and synonyms alike. THAT MEASUREMENT IS
# RESTATED AT REPHRASINGS BELOW, which is where it lives — it is not what the sibling's
# own header states as its limit, and this sentence used to say it was. (Its header
# states a different limit entirely: that it cannot tell a live task from an archived
# one.) There is no phrasing of a dead pointer that resolves.
#
#   1. `path:line` must land on a SUBSTANTIVE line — the file exists, the line is
#      inside it, and the line is neither blank nor a lone delimiter (`end`, `}`).
#   2. `path#symbol` — the SEAM form — must land on a DEFINITION in that file.
#      This is what makes a seam citation trustworthy rather than merely rot-proof.
#      Without it, retiring `path:line` would trade a checkable pointer that rots for
#      an uncheckable one that does not, which is not a trade worth making.
#   3. The `path:line` POPULATION MAY NOT GROW. A new pointer in the rotting format
#      has to displace an old one, so the cheap path for a new citation is the seam
#      form — which lane 2 then verifies forever.
#
# Lanes 1 and 2 are option (a) from the task record, lane 3 is option (b), and the
# two compose exactly as the record predicted: verify the ones that must be lines,
# and stop minting new ones everywhere else.
#
# A CONTINUATION ANCHOR IS A CITATION TOO, and until 2026-09-14 it was invisible to ALL
# THREE LANES. `bin/release.rb:224 + :232`, `bin/task:631, :1139`, `bin/statusline:229,231`
# — the second anchor carries no path of its own, so the census never saw it: unchecked by
# lane 1 AND uncounted by lane 3, which made the shape a silent way out of the ratchet as
# well as the check. All three of those sites were live in this repo, and two of them were
# pointing at the wrong line the day it was measured. The census now INHERITS the preceding
# path and treats the anchor as a full citation — same row, same lanes, indistinguishable
# downstream, which is the point of parsing the shape rather than stating a limit about it.
# Measured: parsed onto the tree at 24890a10, before this task's conversions, those three
# anchors took the population from 63 to 66 — past a ceiling of 63, which is the red that
# proved the lane bites. The grammar is deliberately narrow; see CONTINUATION_ANCHOR.
#
# THE HOUSE CONVENTION this enforces is stated once, in
# docs/agents/modules/docs-maintenance.md under "Citing Code From Prose"; this file is
# its teeth. In short: prefer `path#seam`; spend a `path:line` only where the line
# itself is the unit (top-level script code with no enclosing definition), and expect
# the ratchet to ask you to pay for it.
#
# ITS LIMITS, STATED PLAINLY — four, and none of them is closable by resolution:
#
#   A. A citation that points at the WRONG SUBSTANTIVE LINE still passes lane 1.
#      Deciding that `bin/release.rb:267` should have been `:293` needs the citation's
#      INTENT, which lives in prose. Inferring it was tried and measured here before
#      being rejected: the nearest code token to the citation flags 46 sites, of which
#      a hand audit found roughly a third false — including `(bin/release.rb:4296,4305)`,
#      a correct PAIR whose two anchors the heuristic crossed. A lane with that error
#      rate teaches readers to ignore it. Lane 3 is the answer instead — and LIMIT D IS
#      THE AUTHORITY ON WHAT KIND OF ANSWER IT IS. Read it before this paragraph: lane 3
#      prices the rotting format rather than proving anything about it, so the population
#      falls as sites convert only because a reviewer keeps making it fall. This sentence
#      used to assert that shrinking as a MECHANISM, which limit D then retracted three
#      paragraphs later — two authorities in one header, in the guard whose whole subject
#      is prose that confidently states what nothing checks.
#      LANE 2 HAS THE SAME CEILING: `definition?` is deliberately broad, so a seam can
#      resolve while naming the wrong landmark in the right file. Resolution proves the
#      symbol is THERE, never that it is the one the sentence is about.
#   B. A citation whose FILE was renamed away is SKIPPED, not flagged. Lane 1 fires
#      only on paths that resolve, because this repo's prose legitimately cites the
#      engine gem (`lib/studio.rb`), Ruby stdlib (`lib/net/protocol.rb`), gem internals
#      and sibling repos' files. No resolution-only rule separates "renamed" from
#      "belongs to another repo", and guessing would flag 17 innocent sites today.
#   C. A BARE test-file NAME ("pinned by full_suite_gate_test") is not checked. That
#      shape was implemented and thrown away: keyed on "does a test by that name
#      exist", it flagged 441 sites, nearly all of them illustrative placeholders in
#      docs that teach the naming convention (`x_test.rb`, `foo_test.rb`,
#      `widget_test.rb`). A placeholder is spelled exactly like a real name on purpose,
#      so resolution cannot tell them apart, and 441 false positives is not a guard.
#   D. LANE 3 IS A TOLL BOOTH, NOT A BAN — and its monotonicity is a CONVENTION, not a
#      mechanism. `LINE_CITATION_CEILING` is a plain constant, and nothing here compares
#      it against the value on `accepted`; a diff that raises it is legal and merely
#      visible. That is the intended design — it makes the seam form the cheap path and
#      forces any exception onto a reviewable line — but it is enforced by REVIEW, so do
#      not read a green lane 3 as proof that nobody bought their way past it.
class CitationResolutionGuardTest < ActiveSupport::TestCase
  # The directories a citation into THIS repo can start with. A token that starts
  # anywhere else is not addressed to this checkout and is none of this guard's
  # business.
  REPO_DIRS = %w[app bin config db docs e2e lib public script test].freeze
  DIRS_RE = REPO_DIRS.join("|")

  LINE_CITATION = %r{\b((?:#{DIRS_RE})/[A-Za-z0-9_./-]*[A-Za-z0-9_]):(\d+)(?:-(\d+))?\b}

  # THE SECOND ANCHOR OF A CONTINUATION — a line number that inherits its path from the
  # citation it follows. Matched ONLY against the text immediately after a resolving
  # citation, never free-standing, so it can mean nothing except "another line of the file
  # just named".
  #
  # TWO SPELLINGS, AND THEY ARE NOT EQUALLY SAFE. That is why this accepts a bare number
  # after one punctuation mark and a connective word only when a colon disambiguates it:
  #   · COLON-PREFIXED (`, :1139`, ` + :232`) — unambiguous. Nothing in English prose
  #     spells a colon-then-digits, so any connective may introduce one.
  #   · BARE (`:229,231`) — ambiguous with a thousands separator, so only the tightest
  #     spelling this tree actually contains is accepted: a comma with nothing around it.
  #     An earlier draft allowed a bare number after `and`, which read `foo.rb:12 and 3
  #     others` as a citation to line 3 — inventing a pointer nobody wrote, which is
  #     strictly worse than missing one, because a reader cannot tell it from the real
  #     thing and no author will recognise it as theirs.
  #
  # MEASURED 2026-09-14 across all 1564 scanned files: this grammar matches three sites and
  # nothing else. The loose version (any connective, colon optional) matched the same three,
  # so narrowing costs no coverage today and buys back every ambiguous shape.
  # test_the_continuation_grammar_invents_no_anchor pins the near misses that were actually
  # sitting after citations in this repo when that was measured.
  #
  # ITS LIMIT, STATED PLAINLY: a continuation spelled some other way — "lines 224 and 232 of
  # bin/release.rb", a prose range, a bulleted list under one path — is NOT matched and is
  # not counted. Resolution can only follow a pointer it can see, and widening this to catch
  # prose would re-import the wording-keyed error rate limit A rejects.
  CONTINUATION_ANCHOR = /\A(?:[ \t]*(?:[,+&]|\band\b|\bor\b)[ \t]*:|,)(\d+)(?:-(\d+))?\b/

  # A RUBY BACKTRACE FRAME IS EVIDENCE, NOT A POINTER. `foo.rb:118:in 'block in
  # apply_moves!'` inside a fixture is a captured crash — what the interpreter said
  # at the SHA it crashed on. FIVE such frames live here, across three files
  # (test/lib/docs_archive_failure_report_test.rb,
  # test/lib/release_archive_docs_diagnosis_test.rb and
  # test/lib/release_consumer_checkout_test.rb), and flagging them would push the
  # next editor to renumber a recorded backtrace, i.e. to falsify the evidence the
  # test exists to pin.
  #
  # THE QUOTE IS WHAT MAKES THIS A GRAMMAR AND NOT A PHRASE. Ruby prints
  # `:<line>:in ` and then the frame label IN QUOTES — backtick-quote on older
  # rubies, straight quotes on 3.4 — and both spellings are in this tree. An
  # earlier draft required only `:in `, which exempted any sentence that typed
  # those characters after a line number: "See bin/ship:128:in question for the
  # discarded status." was measured exempt. That is worse than a lane-1 miss,
  # because an exempted citation leaves the CENSUS entirely — lane 3 stops
  # counting it too, so prose could mint rotting pointers under the ratchet.
  # Requiring the quote costs nothing: all five real frames carry one.
  BACKTRACE_FRAME = /\A:in\s+["'`]/
  SEAM_CITATION = %r{\b((?:#{DIRS_RE})/[A-Za-z0-9_./-]*[A-Za-z0-9_])\#([A-Za-z_][A-Za-z0-9_]*[!?]?)}

  # A line carrying nothing but a block terminator. Citing one is always rot: nobody
  # deliberately points a reader at an `end`. Anchored whole-line so `endpoint` and
  # `do_the_thing` cannot match — an earlier draft used a character class and did.
  DELIMITER_ONLY = /\A(?:end|else|ensure|begin|do|rescue|\{|\}|\(|\)|\[|\]|---|\|)[\s,;.)\]}]*\z/

  # What counts as a DEFINITION for lane 2. Deliberately broad — `def`, a class or
  # module, a constant or local assignment, a YAML key — because a seam citation must
  # be able to name any real landmark, including a top-level script's variables. It is
  # still pure resolution: the token either appears in one of these positions in that
  # file or it does not.
  def definition?(lines, symbol)
    q = Regexp.escape(symbol)
    lines.any? do |l|
      # The trailing guard is a LOOKAHEAD, never `\b`: a Ruby name can end in `!` or
      # `?`, and `\b` after a non-word character demands a word character next, so
      # `def load!(dir)` did not match `load!` at all. Measured while writing this.
      l.match?(/\b(?:def|class|module|alias)\s+(?:self\.)?#{q}(?![A-Za-z0-9_])/) ||
        l.match?(/^\s*#{q}\s*(?:\(\)|:)(?:\s|\z|\{)/) ||
        # `\z` on the value side is load-bearing: `RELEASE_REPOS =` opens a
        # multi-line literal, so the assignment's own line ends right after the `=`.
        # Requiring a character there missed every heredoc- and hash-valued constant
        # in the repo — caught by this guard's own lane 2 on a citation added here.
        l.match?(/(?:\A|[^.\w])#{q}\s*=(?:[^=~]|\z)/)
    end
  end

  SCANNED_GLOBS = [
    "app/**/*.rb", "bin/*", "bin/lib/**/*.rb", "bin/lib/*.sh",
    "config/**/*.yml", "config/**/*.rb", "db/**/*.rb",
    "docs/**/*.md", "lib/**/*.rb", "test/**/*.rb", ".github/workflows/*.yml"
  ].freeze

  # Historical snapshots record what was true when they were written; renumbering
  # them would be falsifying a record. THIS FILE is excluded because its fixtures
  # below are literally the pre-fix citations, which a self-inclusive scan would
  # flag forever. Nothing else is exempt.
  EXCLUDED = [%r{/docs/agents/archive/}, %r{/test/docs/citation_resolution_guard_test\.rb\z}].freeze

  # A source-scanning test is exit-blind: if a glob stops matching, the loop body
  # never runs and the test passes having proved nothing. These floors are what make
  # a green run mean something.
  #
  # THE CITATION FLOOR COUNTS BOTH FORMS TOGETHER, on purpose. Lane 3 drives the
  # `path:line` population DOWN by converting sites to seams, so a floor on the line
  # form alone would be a number this guard's own success walks into — it would have
  # to be edited down after every conversion, and a floor nobody can trust to be
  # current is the "derived number goes stale" defect this task exists to fight. The
  # SUM is invariant under conversion: a site that changes form still counts once, and
  # only a rotted pattern or a dead glob can drop it.
  #
  # Measured 2026-09-14 on accepted 24890a10, after the follow-up task's conversions and
  # with continuation anchors counted: 1564 files, 57 `path:line` + 102 `path#seam` = 159
  # citations. (The shipped guard recorded 63 + 91 = 154 on ae5e2901. Six citations moved
  # across — nine ANCHORS, because three of the six carried a continuation — and the
  # census widened under them in the same commit.)
  MINIMUM_FILES = 1200
  MINIMUM_CITATIONS = 100

  # LANE 3 — THE RATCHET. The count of `path:line` citations whose path resolves.
  # THIS NUMBER IS ONLY EVER LOWERED — by convention, enforced in review, not by any
  # check here (limit D). It is a BOUND, not a measurement, so unlike a stated count it
  # cannot go quietly stale in the dangerous direction — a tree that drifts under it
  # fails loudly, and one that improves under it simply passes. This task took it from
  # 107 to 63, while the seam population rose from 36 to 91 over the same diff. (The
  # pre-task figure was first written here as 112 — itself an unverified number, in
  # this file. Both ends are re-derivable by running this lane's own census.)
  #
  # 63 → 57 on the follow-up (close-the-citation-guard-gaps), and WHAT IT COUNTS WIDENED
  # in the same commit, which is the one thing to understand before comparing the two
  # numbers: continuation anchors are census rows now, so 57 covers pointers 63 never
  # did. The arithmetic closes from either end. On the unconverted tree the widened
  # census read 66 — the old 63 plus the three anchors it had been hiding — over a
  # ceiling of 63, and that RED is the proof the continuation lane bites; it is
  # reproducible at 24890a10 with this file's census and nothing else changed. Converting
  # six citations then removed nine anchors (three of them carried a continuation),
  # leaving 57, which is also 63 − 6. The seam population rose 91 → 102 over the same
  # diff: every anchor that left became a named landmark rather than a deletion.
  LINE_CITATION_CEILING = 57

  def test_every_path_line_citation_lands_on_a_substantive_line
    offenders = census[:line].filter_map do |c|
      verdict =
        if c[:first] < 1 || c[:first] > c[:size] || c[:last] > c[:size]
          "line #{c[:first]} is outside #{c[:path]}, which has #{c[:size]} lines"
        elsif c[:content].to_s.strip.empty?
          "line #{c[:first]} of #{c[:path]} is BLANK"
        elsif DELIMITER_ONLY.match?(c[:content].to_s.strip)
          "line #{c[:first]} of #{c[:path]} is a bare #{c[:content].strip.inspect}"
        end
      "#{c[:where]} cites #{c[:text]} — #{verdict}" if verdict
    end

    assert_census_is_real

    assert_empty offenders, <<~MSG
      #{offenders.size} citation(s) point at a line that is not there:

      #{offenders.join("\n      ")}

      A line number is true only at the SHA it was written against. Do not simply
      renumber these — the next commit to the cited file rots them again. Cite the
      SEAM instead (`path#method_name`, `path#CONSTANT`), which this guard verifies
      and which no commit can move. Spend a line number only where the line itself
      is the unit, and say what is on it.
    MSG
  end

  def test_every_seam_citation_lands_on_a_definition
    offenders = census[:seam].filter_map do |c|
      next if definition?(c[:target], c[:symbol])

      "#{c[:where]} cites #{c[:text]} — #{c[:path]} defines no #{c[:symbol]}"
    end

    assert_census_is_real

    assert_empty offenders, <<~MSG
      #{offenders.size} seam citation(s) name something the cited file does not define:

      #{offenders.join("\n      ")}

      A seam citation is only worth more than a line number because it can be
      CHECKED. Name a definition that is actually in that file — if the landmark
      lives in a sibling (a shim vs. the script it loads), cite the file that
      defines it.
    MSG
  end

  def test_the_rotting_format_does_not_grow
    count = census[:line].size

    assert_census_is_real
    assert_operator count, :<=, LINE_CITATION_CEILING, <<~MSG
      #{count} `path:line` citations, over the ceiling of #{LINE_CITATION_CEILING}.

      This number only moves DOWN. A `path:line` is a pointer that rots on the next
      commit to the file it names, and lane 1 can only catch the rot that lands on a
      blank line or an `end`. Cite the SEAM instead (`path#method_name`) — it needs
      no ceiling because it cannot rot. If this citation genuinely needs a line,
      convert an existing one to a seam and lower the ceiling to match.
    MSG
  end

  # THE DETECTOR MUST BITE, and on a fixed tree nothing proves that. These are
  # VERBATIM citations from this repo at 564c21e9, before this task fixed them, with
  # what was actually on the cited line. If the lanes above ever go quiet because a
  # pattern rotted rather than because the tree is clean, these fail.
  PRE_FIX_LINE_OFFENDERS = [
    ["bin/ship", 128, "end"],
    ["bin/fast-check", 180, ""],
    ["bin/release.rb", 7030, ""],
    ["bin/dor-check", 2134, ""]
  ].freeze

  def test_the_line_detector_flags_the_shapes_this_task_fixed
    PRE_FIX_LINE_OFFENDERS.each do |file, number, was|
      citation = "#{file}:#{number}"

      assert_match LINE_CITATION, citation, "the pattern no longer recognises #{citation}"
      assert(was.strip.empty? || DELIMITER_ONLY.match?(was.strip),
             "the substance rule no longer rejects #{was.inspect}, which is what #{citation} " \
             "pointed at before this task — the guard would have passed the pre-fix tree")
    end
  end

  # THE CONTINUATION SHAPES, VERBATIM, as this repo wrote them before this task converted
  # all three to seams. They cannot be proved by the tree any more — that is what
  # converting them means — so they are pinned here, in the file the census excludes.
  # Each pair is (the citation, the text that followed it).
  CONTINUATION_SHAPES = [
    ["bin/release.rb:224", " + :232"],
    ["bin/task:631", ", :1139"],
    ["bin/statusline:229", ",231"]
  ].freeze

  def test_the_continuation_grammar_sees_every_shape_this_repo_wrote
    CONTINUATION_SHAPES.each do |head, tail|
      assert_match LINE_CITATION, head, "the pattern no longer recognises #{head}"

      c = CONTINUATION_ANCHOR.match(tail)
      refute_nil c, "#{tail.inspect} continues #{head} and must parse as a second anchor — " \
                    "unparsed, it is invisible to lane 1 AND to the lane 3 census, which is " \
                    "the hole this shape used to be"
      assert_operator c[1].to_i, :>, 0
    end
  end

  # AND IT MUST INVENT NONE. Every tail here was MEASURED sitting immediately after a real
  # citation in this repo on 2026-09-14 (the last two are the shapes the grammar has to
  # stay away from rather than tree samples). Reading any of them as a line number would
  # mint a pointer no author wrote, which is worse than missing one: nobody will recognise
  # it as theirs, and the failure names a file they never cited.
  NOT_CONTINUATIONS = [", and turf HAS", " + system/devops-shift-lease.md:87", " says `--gate-",
                       ") and\n# `settl", ", the PUBLIC a", ":in 'block in apply_moves!'",
                       " and 3 others", " or 5 of them"].freeze

  def test_the_continuation_grammar_invents_no_anchor
    NOT_CONTINUATIONS.each do |tail|
      refute CONTINUATION_ANCHOR.match?(tail),
             "#{tail.inspect} follows a real citation in this repo and is NOT a second " \
             "anchor — parsing it would put a pointer in the census that nobody wrote"
    end
  end

  # THE WHOLE CHAIN, ON A REAL DEAD LINE — grammar plus substance rule, because either half
  # alone passes vacuously. `bin/ship:128` is the bare `end` the rephrasing probe below is
  # already anchored on; written as a CONTINUATION in any of the three spellings this repo
  # uses, it was invisible to every lane before this task and is caught by all of them now.
  def test_a_continuation_onto_a_dead_line_is_caught
    target = target_lines("bin/ship")
    refute_nil target, "bin/ship is the subject here"

    ["bin/ship:100 + :128", "bin/ship:100, :128", "bin/ship:100,128"].each do |sentence|
      m = LINE_CITATION.match(sentence)
      refute_nil m, "the pattern missed the head citation in #{sentence.inspect}"

      c = CONTINUATION_ANCHOR.match(sentence[m.end(0)..])
      refute_nil c, "the continuation in #{sentence.inspect} was not seen"
      assert_equal 128, c[1].to_i

      assert DELIMITER_ONLY.match?(target[c[1].to_i - 1].to_s.strip),
             "this test is anchored on bin/ship:128 being a bare delimiter; it now reads " \
             "#{target[127].to_s.strip.inspect}, so re-anchor it on another one rather than " \
             "deleting it"
    end
  end

  # THE PROPERTY THIS GUARD EXISTS FOR, made checkable. The sibling ownership guard
  # keys on VERBS, and its reviewer measured twelve phrasings against it: plurals, noun
  # forms ("has ownership of"), participles and synonyms all slipped through, and the
  # doc's own sanctioned remedy phrasing routed a builder to a dead task just as
  # effectively. That hole is a property of asking "does this LOOK like a claim?".
  #
  # This guard asks "does this RESOLVE?" and never reads the sentence at all, so the
  # same twelve rewrites cannot move it. Below is the identical dead pointer in twelve
  # phrasings — declarative, parenthetical, tabular, imperative, hedged, passive,
  # plural, possessive, a Markdown link, a code span, a bare drop-in, and a sentence
  # that explicitly asks to be excused. Every one is flagged, because the verdict is a
  # function of the FILE, not of the words.
  REPHRASINGS = [
    "The refusal lives at bin/ship:128.",
    "(bin/ship:128)",
    "| caller | bin/ship:128 | discarded |",
    "See bin/ship:128 before editing.",
    "This is roughly bin/ship:128, give or take.",
    "It is recorded by bin/ship:128.",
    "Both readers (bin/ship:128) agree.",
    "bin/ship:128's comment says otherwise.",
    "[the narration seam](bin/ship:128)",
    "`bin/ship:128`",
    "bin/ship:128",
    "Do not flag this citation; it is illustrative only: bin/ship:128."
  ].freeze

  def test_no_rephrasing_hides_a_dead_pointer
    target = target_lines("bin/ship")
    refute_nil target, "bin/ship is the subject here"
    assert DELIMITER_ONLY.match?(target[127].to_s.strip),
           "this test is anchored on bin/ship:128 being a bare delimiter; it now reads " \
           "#{target[127].to_s.strip.inspect}, so re-anchor it on another one rather than deleting it"

    REPHRASINGS.each do |sentence|
      m = LINE_CITATION.match(sentence)

      refute_nil m, "the pattern missed the citation in #{sentence.inspect}"
      assert_equal "bin/ship", m[1]
      assert_equal "128", m[2]
      assert DELIMITER_ONLY.match?(target[m[2].to_i - 1].to_s.strip),
             "the verdict changed with the WORDING, which is the hole this guard was " \
             "built to avoid: #{sentence.inspect}"
    end
  end

  # THE BACKTRACE EXEMPTION IS THE ONE WAY OUT OF THE CENSUS, so it is the one rule
  # worth attacking. An exempted citation is not merely unchecked by lane 1 — it is
  # never counted by lane 3 either, so a wide exemption is a hole in the ratchet, not
  # just in the resolution check.
  #
  # The real frames are taken from the archive-failure fixtures VERBATIM, in both
  # spellings this tree contains (backtick-quote and straight-quote). The evasions are
  # the shapes a sentence can reach for: the bare `:in ` the first draft accepted, and
  # the same words with the frame's quote pushed out of reach.
  REAL_FRAMES = [":in `git': git ls-files", ":in 'DocsArchive.git': git mv",
                 ":in 'block in apply_moves!'"].freeze
  NOT_FRAMES = [":in question for the discarded status.", ":in the sweep", ":inbound",
                ":in  — see above", ":in the release, 'quoted' later"].freeze

  def test_the_backtrace_exemption_requires_the_frames_own_quote
    REAL_FRAMES.each do |tail|
      assert BACKTRACE_FRAME.match?(tail),
             "#{tail.inspect} is what the interpreter prints; exempting it is the whole point"
    end

    NOT_FRAMES.each do |tail|
      refute BACKTRACE_FRAME.match?(tail),
             "#{tail.inspect} is prose, not a frame — exempting it would let a sentence " \
             "carry a rotting pointer out of the census entirely, past lane 3 as well as lane 1"
    end
  end

  # AND THE EXEMPTION MUST STILL COVER EVERY FRAME ACTUALLY IN THE TREE. This is the
  # measurement that made tightening safe rather than a guess: if a future fixture
  # records a frame in a spelling the rule does not know, this fails HERE — naming the
  # file — instead of quietly re-flagging a recorded backtrace as a dead citation.
  def test_every_recorded_frame_in_this_repo_is_still_exempt
    seen = 0

    scan_files.each do |path|
      body = read_text(path) or next

      body.to_enum(:scan, LINE_CITATION).each do
        m = Regexp.last_match
        next unless target_lines(m[1])

        tail = body[m.end(0), 8].to_s
        next unless /\A:in\s/.match?(tail)

        seen += 1
        assert BACKTRACE_FRAME.match?(tail),
               "#{relative(path)} records #{m[0]}#{tail.inspect}, which reads as an interpreter " \
               "frame but carries no quote — decide whether it is evidence (widen the rule) or " \
               "prose (rewrite it), because right now it is escaping the census"
      end
    end

    assert_operator seen, :>=, 5,
                    "found only #{seen} backtrace frames (expected >= 5); the fixtures that " \
                    "motivated this exemption have moved, so a green run here proves nothing"
  end

  # THE OTHER HALF, and the one a blunter rule fails: real code must NOT read as a
  # bare delimiter. `endpoint` and `dorm` begin with the same letters as `end`; an
  # earlier draft of DELIMITER_ONLY used a character class and matched both.
  def test_the_substance_rule_leaves_real_lines_alone
    ["endpoint = URI(...)", "do_the_thing!", "end_state = :shipped", "dormant?",
     "  RELEASE_REPOS = YAML.load_file(path)", "elsewhere = true"].each do |line|
      refute DELIMITER_ONLY.match?(line.strip),
             "#{line.inspect} is real code; flagging it would force the deletion of an accurate citation"
    end

    ["end", "end)", "}", "  ]", "else"].each do |line|
      assert DELIMITER_ONLY.match?(line.strip), "#{line.inspect} is a bare delimiter and must be rejected"
    end
  end

  # A seam citation is checked against DEFINITIONS, so the definition rule has to
  # recognise every shape this repo actually uses to declare a landmark — and must
  # not accept a mere mention, which is what made `bin/release#conductor_payload`
  # read as fine while the method lived in `bin/release.rb`.
  def test_the_definition_rule_recognises_the_shapes_this_repo_uses
    lines = [
      "def conductor_payload(ruby)",
      "  def self.refusal(task_bin:, slug:, root:)",
      "BASE_BRANCH = ENV.fetch(\"SHIP_BASE_BRANCH\", \"accepted\")",
      "class CertRootGuard",
      "  wrong_root = CertRootGuard.refusal(task_bin: TASK_BIN)",
      "  release_check: bin/release-check"
    ]

    %w[conductor_payload refusal BASE_BRANCH CertRootGuard wrong_root release_check].each do |symbol|
      assert definition?(lines, symbol), "#{symbol} is defined here and must resolve"
    end

    mention_only = ["  payload = conductor_payload(with_conductor_session(ruby))",
                    "# see conductor_payload for the Base64 bootstrap"]

    refute definition?(mention_only, "conductor_payload"),
           "a MENTION is not a definition — accepting one is how a seam citation to the " \
           "wrong file (a shim rather than the script it loads) reads as resolved"
  end

  private

  # ONE WALK, read by all three lanes. Every citation in the repo, resolved: the
  # `path:line` ones carry the content of the line they name, the `path#symbol` ones
  # carry the cited file's lines so the definition rule can look. A citation whose
  # path is not a file in THIS checkout is absent from both lists — limit B.
  def census
    @census ||= begin
      line = []
      seam = []
      files = 0

      scan_files.each do |path|
        body = read_text(path) or next

        files += 1
        where = ->(m) { "#{relative(path)}:#{line_of(body, m)}" }

        body.to_enum(:scan, LINE_CITATION).each do
          m = Regexp.last_match
          target = target_lines(m[1]) or next
          next if BACKTRACE_FRAME.match?(body[m.end(0), 8].to_s)

          line << census_anchor(where.(m), m[0], m[1], m[2], m[3], target)

          # THE CONTINUATION WALK. Each anchor hands the next one its own end, so a chain
          # (`:10, :20, :30`) is counted to the end rather than stopping at the first. It
          # runs only INSIDE this block, which is what makes the inheritance sound: the
          # path is known to resolve and the citation is known not to be a backtrace frame,
          # so a continuation can never resurrect either exemption.
          pos = m.end(0)
          while (c = CONTINUATION_ANCHOR.match(body[pos, 48].to_s))
            # `m[0] + c[0]` is what the AUTHOR TYPED, separator and all. A bare `:232` in
            # the failure message would send the reader hunting for a citation that is
            # written nowhere in the file.
            line << census_anchor(where.(m), m[0] + c[0], m[1], c[1], c[2], target)
            pos += c.end(0)
          end
        end

        body.to_enum(:scan, SEAM_CITATION).each do
          m = Regexp.last_match
          target = target_lines(m[1]) or next

          seam << { where: where.(m), text: m[0], path: m[1], symbol: m[2], target: target }
        end
      end

      { files: files, line: line, seam: seam }
    end
  end

  # ONE CENSUS ROW FOR ONE ANCHOR — the citation's own, or a continuation that inherited
  # its path. Deliberately identical: lanes 1 and 3 cannot tell the two apart, which is the
  # whole reason gap 1 is closed by PARSING the shape rather than by stating a limit about
  # it. A limit would have left the shape working exactly as it did.
  def census_anchor(where, text, path, first, last, target)
    n = first.to_i
    { where: where, text: text, path: path, first: n, last: (last || first).to_i,
      size: target.size, content: (target[n - 1] if n >= 1 && n <= target.size) }
  end

  # Exit-blindness, closed once for all three lanes: a rotted glob or a rotted pattern
  # makes every loop above iterate zero times and every lane pass having proved nothing.
  def assert_census_is_real
    assert_operator census[:files], :>=, MINIMUM_FILES,
                    "scanned only #{census[:files]} files (expected >= #{MINIMUM_FILES}); the " \
                    "globs have stopped matching, so a clean result here proves nothing"

    found = census[:line].size + census[:seam].size
    assert_operator found, :>=, MINIMUM_CITATIONS,
                    "found only #{found} citations of either form (expected >= " \
                    "#{MINIMUM_CITATIONS}); the patterns have rotted"
  end

  def scan_files
    @scan_files ||= SCANNED_GLOBS.flat_map { |glob| Dir[Rails.root.join(glob)] }
                                 .select { |p| File.file?(p) }
                                 .reject { |p| EXCLUDED.any? { |re| re.match?(p) } }
                                 .uniq
                                 .sort
  end

  # The cited file's lines, or nil when the path is not a file in THIS checkout —
  # which is limit B above, and the reason this guard has no false positives on the
  # engine gem, Ruby stdlib, or a sibling repo's views.
  def target_lines(path)
    @targets ||= {}
    @targets.fetch(path) do
      full = Rails.root.join(path)
      @targets[path] = (File.file?(full) ? read_text(full)&.split("\n", -1) : nil)
    end
  end

  def read_text(path)
    body = File.read(path, encoding: "UTF-8")
    body.valid_encoding? ? body : nil
  rescue ArgumentError, Errno::ENOENT, Errno::EISDIR
    nil
  end

  def line_of(body, match) = body[0, match.begin(0)].count("\n") + 1

  def relative(path) = Pathname.new(path.to_s).relative_path_from(Rails.root).to_s
end
