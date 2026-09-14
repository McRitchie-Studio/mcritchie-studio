# frozen_string_literal: true

require "test_helper"

# A LINE NUMBER IS TRUE ONLY AT THE SHA IT WAS WRITTEN AGAINST.
#
# Found 2026-09-14 across three reviews in one day. Eight `bin/release.rb:<line>`
# citations elsewhere in this repo were spot-checked after one ordinary commit
# shifted that file; ALL EIGHT were already pointing at unrelated lines, one at a
# blank line. Two more sat in a single table cell of the QA-release SOP, eleven
# words from the sentence announcing the cite-the-seam discipline. A third review
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
# sibling guard measured exactly that hole against twelve phrasings (see the limit it
# states in its own header). There is no phrasing of a dead pointer that resolves.
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
# THE HOUSE CONVENTION this enforces is stated once, in
# docs/agents/modules/docs-maintenance.md under "Citing Code From Prose"; this file is
# its teeth. In short: prefer `path#seam`; spend a `path:line` only where the line
# itself is the unit (top-level script code with no enclosing definition), and expect
# the ratchet to ask you to pay for it.
#
# ITS LIMITS, STATED PLAINLY — three, and none of them is closable by resolution:
#
#   A. A citation that points at the WRONG SUBSTANTIVE LINE still passes lane 1.
#      Deciding that `bin/release.rb:267` should have been `:293` needs the citation's
#      INTENT, which lives in prose. Inferring it was tried and measured here before
#      being rejected: the nearest code token to the citation flags 46 sites, of which
#      a hand audit found roughly a third false — including `(bin/release.rb:4296,4305)`,
#      a correct PAIR whose two anchors the heuristic crossed. A lane with that error
#      rate teaches readers to ignore it. Lane 3 is the answer instead: the format that
#      can rot this way stops growing, and shrinks as sites convert.
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
class CitationResolutionGuardTest < ActiveSupport::TestCase
  # The directories a citation into THIS repo can start with. A token that starts
  # anywhere else is not addressed to this checkout and is none of this guard's
  # business.
  REPO_DIRS = %w[app bin config db docs e2e lib public script test].freeze
  DIRS_RE = REPO_DIRS.join("|")

  LINE_CITATION = %r{\b((?:#{DIRS_RE})/[A-Za-z0-9_./-]*[A-Za-z0-9_]):(\d+)(?:-(\d+))?\b}

  # A RUBY BACKTRACE FRAME IS EVIDENCE, NOT A POINTER. `foo.rb:118:in 'block in
  # apply_moves!'` inside a fixture is a captured crash — what the interpreter said
  # at the SHA it crashed on. Two such frames live in the archive-failure fixtures,
  # and flagging them would push the next editor to renumber a recorded backtrace,
  # i.e. to falsify the evidence the test exists to pin. The exemption is the
  # interpreter's own frame GRAMMAR (`:<line>:in `), not a phrase, so it cannot be
  # borrowed by prose that merely wants to be excused.
  BACKTRACE_FRAME = /\A:in\s/
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
  # Measured 2026-09-14 at 564c21e9, after this task's conversions: 1561 files,
  # 77 `path:line` + 72 `path#seam` = 149 citations.
  MINIMUM_FILES = 1200
  MINIMUM_CITATIONS = 100

  # LANE 3 — THE RATCHET. The count of `path:line` citations whose path resolves.
  # THIS NUMBER ONLY EVER MOVES DOWN. It is a BOUND, not a measurement, so unlike a
  # stated count it cannot go quietly stale in the dangerous direction — a tree that
  # drifts under it fails loudly, and one that improves under it simply passes. This
  # task took it from 112 to 77 by converting 35 citations to seams.
  LINE_CITATION_CEILING = 77

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

          first = m[2].to_i
          line << { where: where.(m), text: m[0], path: m[1], first: first,
                    last: (m[3] || m[2]).to_i, size: target.size,
                    content: (target[first - 1] if first >= 1 && first <= target.size) }
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
