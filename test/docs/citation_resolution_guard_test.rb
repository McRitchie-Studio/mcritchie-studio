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
# WHAT THIS GUARD DOES, in five lanes. NONE OF THEM READS THE PROSE around a citation,
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
#      A RANGE IS CHECKED AT BOTH ENDS: `path:a-b` whose LAST line is a bare `end` has
#      slid off its subject, because a range is cut to fit a passage.
#   2. `path#symbol` — the SEAM form — must land on a DEFINITION in that file.
#      This is what makes a seam citation trustworthy rather than merely rot-proof.
#      Without it, retiring `path:line` would trade a checkable pointer that rots for
#      an uncheckable one that does not, which is not a trade worth making.
#   3. The `path:line` POPULATION MAY NOT GROW. A new pointer in the rotting format
#      has to displace an old one, so the cheap path for a new citation is the seam
#      form — which lane 2 then verifies forever.
#   4. A DECLARED ANCHOR must be in the span that names it. `path:line#"what is on it"`
#      carries its own subject, so when the file moves the citation says so itself
#      instead of resolving quietly onto a stranger. This is the only lane that reads
#      CONTENT — and it still reads no prose: the author DECLARES the token, the lane
#      only looks it up. Limit A tried to INFER that token and measured a third false.
#   5. The UNANCHORED population may not grow either. Lanes 3 and 5 together are what
#      make lane 4 mandatory for new work: a new `path:line` must displace an old one
#      AND must be anchored, without a retrofit of the 49 that are not.
#
# Lanes 1 and 2 are option (a) from the first task record, lane 3 is option (b), and the
# two compose exactly as that record predicted: verify the ones that must be lines, and
# stop minting new ones everywhere else. Lanes 4 and 5 are the second record's (a) and
# (b) — added 2026-09-22 after four citations rotted onto SUBSTANTIVE lines in one night
# across three PRs, green on all three lanes, with nothing but a reviewer's eye between
# them and the tree. They are pinned at MISPOINTED_CITATIONS, verbatim, all four — with a
# fifth row that is not a defect but the PROBE for the one recorded miss, folded in
# 2026-09-22 so the negative result and its proof travel together.
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
# proved the lane bites. The grammar is deliberately narrow — narrower now than the day it
# landed, because its bare-comma branch read `bin/release.rb:8,370` as two anchors and
# `bin/ship:100,128` and `bin/statusline:229,231` are the same string as a thousands
# separator. `bin/statusline:229,231` is therefore the one of those three shapes this
# grammar no longer reads, and it is pinned as a known miss in UNREAD_CONTINUATIONS. See
# CONTINUATION_ANCHOR for the measurement behind that trade.
#
# THE HOUSE CONVENTION this enforces is stated once, in
# docs/agents/modules/docs-maintenance.md under "Citing Code From Prose"; this file is
# its teeth. In short: prefer `path#seam`; spend a `path:line` only where the line
# itself is the unit (top-level script code with no enclosing definition), and expect
# the ratchet to ask you to pay for it.
#
# ITS LIMITS, STATED PLAINLY — four, and none of them is closable by resolution:
#
#   A. A BARE citation that points at the WRONG SUBSTANTIVE LINE still passes lane 1.
#      Deciding that `bin/release.rb:267` should have been `:293` needs the citation's
#      INTENT, which lives in prose. Inferring it was tried and measured here before
#      being rejected: the nearest code token to the citation flags 46 sites, of which
#      a hand audit found roughly a third false — including `(bin/release.rb:4296,4305)`,
#      a correct PAIR whose two anchors the heuristic crossed. A lane with that error
#      rate teaches readers to ignore it.
#      LANE 4 CLOSES THIS FOR ANCHORED CITATIONS, and for those only, by asking the
#      author to DECLARE the token instead of guessing it. What it closes is ROT — a
#      citation that was right when written and whose file moved under it. It does NOT
#      close WRONG AT BIRTH: an author reading the wrong line copies the anchor off
#      that same wrong line, and the pair is self-consistent forever. Nothing here can
#      reach that, and defect D of MISPOINTED_CITATIONS is what it looks like — a range
#      that swallowed the paragraph CONTRADICTING the sentence that cited it, ending
#      substantive, carrying its anchor, and wrong. Lanes 3 and 5 price the rest — and
#      LIMIT D IS
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
#   D. LANES 3 AND 5 ARE TOLL BOOTHS, NOT BANS — and their monotonicity is a CONVENTION,
#      not a mechanism. `LINE_CITATION_CEILING` and `UNANCHORED_LINE_CITATION_CEILING`
#      are plain constants, and nothing here compares either against the value on
#      `accepted`; a diff that raises one is legal and merely visible. That is the
#      intended design — it makes the seam form the cheap path and forces any exception
#      onto a reviewable line — but it is enforced by REVIEW, so do not read a green
#      lane 3 or 5 as proof that nobody bought their way past it. Lane 5 is the softer
#      of the two by construction: raising it costs a reviewer's attention, whereas
#      raising lane 3's also has to survive the question of why a seam would not do.
class CitationResolutionGuardTest < ActiveSupport::TestCase
  # The directories a citation into THIS repo can start with. A token that starts
  # anywhere else is not addressed to this checkout and is none of this guard's
  # business.
  REPO_DIRS = %w[app bin config db docs e2e lib public script test].freeze
  DIRS_RE = REPO_DIRS.join("|")

  # THE DECLARED ANCHOR — `path:line#"what is on it"`, lane 4's whole subject.
  #
  # IT IS DECLARED, NOT INFERRED, and that distinction is the reason this lane exists
  # where limit A's rejected heuristic did not. Limit A tried to GUESS the anchor from
  # the nearest code token to the citation: 46 sites flagged, roughly a third of them
  # false on a hand audit, including a correct PAIR whose two anchors it crossed. A
  # guess can be wrong. A declaration cannot be wrong about ITSELF — the author writes
  # the token, and the guard only asks whether the cited span contains it. The false
  # positive rate of this lane is structurally zero: a citation with no `#` anchor is
  # not in it at all.
  #
  # THREE SPELLINGS, because a line is not always an identifier. `#"quoted"` for a
  # phrase (the only form that can carry `--gate-role review` or a comment sentence),
  # `#`backticked`` for the same inside Markdown prose that is already code-spanning,
  # and a bare `#token` for the common case where the landmark IS a Ruby name. Minimum
  # three characters: `#"a"` would match every line in every file and pin nothing.
  #
  # `#` IS THE HOUSE'S OWN LANDMARK MARKER, borrowed deliberately from SEAM_CITATION so
  # the family reads as one grammar: `path#symbol` is a landmark with no line,
  # `path:line#anchor` is a landmark WITH one, and dropping the `:line` from the second
  # is the conversion lane 3 is asking for. It cannot collide with SEAM_CITATION —
  # that pattern needs `#` directly after a path, and a path may not contain `:`.
  # Measured across the scanned corpus before this lane landed: ZERO occurrences of
  # `path:<digits>#`, so widening the citation grammar re-read no existing prose.
  #
  # A YAML `#` DOES NOT START A COMMENT HERE. YAML needs whitespace before an inline
  # `#`; this one sits hard against a digit, so `bin/dor-check:44-47#"FAST route"` is a
  # scalar in config/feature_shapes.yml exactly as written.
  ANCHOR = %r{\#(?:"([^"\n]{3,80})"|`([^`\n]{3,80})`|([A-Za-z_][A-Za-z0-9_]{2,}[!?]?))}

  # A LEADING COMMENT MARKER IS NOT CONTENT. Dropping it is what lets an anchor be read
  # the way a human reads the passage — and what lets a phrase that WRAPS across two
  # comment lines be found, since the join would otherwise splice a `#` into the middle
  # of it. `#` and `//` only: stripping a leading `--` would eat `--gate-role`, which is
  # exactly the kind of anchor this lane exists to carry.
  COMMENT_LEAD = %r{\A\s*(?:\#+|//)\s?}

  # The citation, with its anchor OPTIONAL. Groups 1-3 are unchanged — path, first,
  # last — so every lane, fixture and continuation that reads them is untouched; the
  # anchor arrives as groups 4-6 and is read only through `anchor_of`. Making it part
  # of `m[0]` is deliberate: the text a failure prints stays greppable in the body.
  LINE_CITATION = %r{\b((?:#{DIRS_RE})/[A-Za-z0-9_./-]*[A-Za-z0-9_]):(\d+)(?:-(\d+))?\b(?:#{ANCHOR.source})?}

  # THE SECOND ANCHOR OF A CONTINUATION — a line number that inherits its path from the
  # citation it follows. Matched ONLY against the text immediately after a resolving
  # citation, never free-standing, so it can mean nothing except "another line of the file
  # just named".
  #
  # A COLON IS REQUIRED. The connective may be anything a sentence reaches for — `, :1139`,
  # ` + :232`, ` and :44` — but the number itself must be introduced by a colon, because
  # nothing in English prose spells a colon-then-digits and everything else does.
  #
  # AN EARLIER DRAFT ALSO ACCEPTED A BARE NUMBER AFTER A COMMA (`:229,231`), justified here
  # as "the tightest spelling this tree actually contains". That justification was wrong in
  # the one way that mattered: it named the thousands separator as the hazard the narrowing
  # defends against, and `,231` IS the thousands separator — the two are the same string,
  # with no feature of either that tells them apart. What the narrowing actually removed was
  # the `and 3 others` case below. Measured on the shipped grammar, the bare branch invented:
  #   · `bin/release.rb:8,370` → anchors at line 8 AND line 370. Both resolve, so no lane
  #     says a word and the ratchet silently charges two tolls for one pointer.
  #   · `bin/ship:100,000`     → anchor at line 0, which lane 1 then reds as "outside
  #     bin/ship" — the guard accusing correct prose, the worst failure it has.
  #   · `x.rb:1,2,3`           → two phantom anchors chained off one citation.
  # Reachability is ordinary: 132 comma-grouped numbers already sit in the scanned corpus,
  # and 8 of the 46 files this repo cites by line are over 999 lines long, so a separator is
  # the NATURAL spelling of a line number in them.
  #
  # DROPPING IT COST ONE DETECTION, EVER. Measured across all 1565 scanned files today the
  # bare branch matches nothing; measured across the 1564 files at 24890a10, before the
  # sites converted, its entire yield in the history of this repo was ONE — the
  # `bin/statusline:229,231` in test/lib/devops_shift_argument_guard_test.rb — and review
  # re-derived both of its anchors as CORRECT. So the branch has never caught rot, and an
  # invention is strictly worse than a miss: nobody will recognise the pointer as theirs,
  # and the failure names a file they never cited.
  #
  # A VERSION NUMBER IS NOT A LINE NUMBER either. `(?!\.\d)` is why ` and :3.4.1` no longer
  # mints an anchor at line 3; a sentence-ending `:232.` is untouched, because the guard
  # looks for a digit after the dot, not for the dot.
  #
  # MEASURED 2026-09-14 across all 1565 scanned files: this grammar matches nothing at all —
  # every continuation this repo ever wrote is now a seam. That is exactly why
  # test_the_continuation_walk_follows_a_chain_to_its_end drives it from fixtures instead of
  # from the tree, and why CONTINUATION_SHAPES pins the spellings verbatim.
  # test_the_continuation_grammar_invents_no_anchor pins the near misses that were actually
  # sitting after citations in this repo when that was measured.
  #
  # ITS LIMIT, STATED PLAINLY: a continuation spelled some other way — the bare `:229,231`
  # above, "lines 224 and 232 of bin/release.rb", a prose range, a bulleted list under one
  # path — is NOT matched and is not counted. Those shapes stay a silent way past lane 3,
  # which is a real hole and is the price of never inventing. Resolution can only follow a
  # pointer it can see, and widening this to catch prose would re-import the wording-keyed
  # error rate limit A rejects.
  CONTINUATION_ANCHOR = /\A[ \t]*(?:[,+&]|\band\b|\bor\b)[ \t]*:(\d+)(?:-(\d+))?(?!\.\d)\b/

  # How much text after a citation is offered to CONTINUATION_ANCHOR. It is a WINDOW, not
  # the rest of the line, so a number further down the sentence can never be adopted as a
  # second anchor; the pattern is anchored at `\A` against it.
  WINDOW = 48

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
  # Measured 2026-09-14 on accepted 9c5c25ab, after the follow-up task's conversions and
  # with continuation anchors counted: 1565 files, 57 `path:line` + 103 `path#seam` = 160
  # citations. (This paragraph first recorded 1564 / 57 / 102 against **24890a10** — which
  # is the BASE the follow-up branched from, where the real figures are 1564 / 66 / 91.
  # 57 + 102 was the branch HEAD; the merge added a file and a seam. A count and the SHA it
  # was taken at rot apart exactly like a citation and its line, which is why the floors
  # below are the mechanism and this sentence is only a record.
  # The shipped guard recorded 63 + 91 = 154 on ae5e2901. Six citations moved across — nine
  # ANCHORS, because three of the six carried a continuation — and the census widened under
  # them in the same commit.)
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
  # ceiling of 63, and that RED is the proof the continuation lane bites. It is still
  # reproducible at 24890a10 with this file's census and nothing else changed, but it reads
  # 65 THERE NOW, not 66: one of those three was the bare `bin/statusline:229,231`, which
  # this grammar no longer reads (see CONTINUATION_ANCHOR). 65 over 63 is the same red for
  # the same reason. Converting six citations then removed nine anchors (three of them
  # carried a continuation), leaving 57, which is also 63 − 6. The seam population rose
  # 91 → 102 over the same diff, and 103 once it merged: every anchor that left became a
  # named landmark rather than a deletion.
  #
  # 57 -> 55 on this task (citations-resolve-but-mislead). NOTHING WAS CONVERTED to earn
  # those two: 57 was the value the follow-up left, and the tree underneath it had already
  # drifted to 55 by ordinary deletion. Lowering a bound onto the measured count is what
  # keeps it a BOUND rather than slack — at 57 the next two rotting pointers were prepaid.
  LINE_CITATION_CEILING = 55

  # LANE 5 — THE SECOND RATCHET, over the citations that carry NO declared anchor. It is
  # a strictly tighter bound sharing lane 3's mechanism, and the two together are what
  # make lane 4 mandatory for new work without a 55-site retrofit: a new `path:line` must
  # displace an old one (lane 3) AND must be anchored (lane 5), because the unanchored
  # population cannot grow either. The cheap paths stay, in order: a SEAM costs nothing
  # and cannot rot; an ANCHORED line costs a toll but rots LOUDLY; a bare line costs the
  # same toll and rots in silence, which is the trade this lane finally prices.
  #
  # ANCHORING IS NOT FREE, deliberately. An anchored citation into a file that moves often
  # reds an unrelated PR on every slide until someone re-derives it. That is a real cost,
  # and it is why anchoring buys no discount against lane 3: the SEAM stays the only form
  # that is free, because it is the form this house actually wants.
  #
  # Measured on this task's tree: 55 `path:line` citations, 6 anchored, 49 bare.
  UNANCHORED_LINE_CITATION_CEILING = 49

  def test_every_path_line_citation_lands_on_a_substantive_line
    offenders = census[:line].filter_map do |c|
      verdict = substance_verdict(c)
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

      A RANGE THAT ENDS ON A BARE `end` HAS SLID OFF ITS SUBJECT. It is not merely
      untidy: the range was cut to fit a passage, so when its LAST line is a block
      terminator the passage is gone and the number is pointing at whatever code now
      occupies that offset. Do not trim the range by one to silence this — re-derive
      where the passage went, or anchor the citation so the next slide says so itself.
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

  # LANE 4 — THE ANCHOR. The one lane that reads what a line SAYS, and this guard's only
  # answer to limit A. It does not INFER the claim from prose — limit A measured that at
  # roughly a third false and rejected it. The author DECLARES a token, and the lane asks
  # the single question resolution can answer about content: is it inside the span you
  # named? A declaration cannot be wrong about itself, so this lane's false-positive rate
  # is structurally zero: a citation with no anchor is not in it at all.
  #
  # WHAT IT CATCHES AND WHAT IT CANNOT. It catches ROT — a citation that was right when it
  # was written and whose file moved under it — permanently, on every anchored site. It
  # does NOT catch a citation that was WRONG AT BIRTH: an author reading the wrong line
  # copies the anchor off that same wrong line, and the pair is self-consistent. Those are
  # different failures and only the first is mechanical. A green lane 4 means the pointer
  # still lands where its author put it — never that the sentence around it is true.
  #
  # A COMMON ANCHOR PINS LOOSELY. `--gate-role review` is on 11 lines of bin/dor-check, so
  # rot could slide from one to another and stay green; `reviewers run --gate-role review`
  # is on exactly one. That is the author's judgement to make. Refusing a common anchor is
  # NOT the remedy — nothing here can tell a loose anchor from a file that legitimately
  # repeats itself, and refusing would accuse correct prose, the worst failure a guard has.
  def test_every_anchored_citation_carries_its_anchor_at_the_line_it_names
    offenders = census[:line].filter_map do |c|
      next unless c[:anchor]
      next if c[:first] < 1 || c[:first] > c[:size] || c[:last] > c[:size]
      next if anchor_in_span?(c)

      anchor_offender(c)
    end

    assert_census_is_real

    assert_empty offenders, anchor_lane_message(offenders)
  end

  # LANE 5 — the unanchored ratchet. Its reasoning is at UNANCHORED_LINE_CITATION_CEILING.
  def test_a_new_line_citation_declares_its_anchor
    bare = census[:line].count { |c| c[:anchor].nil? }

    assert_census_is_real
    assert_operator bare, :<=, UNANCHORED_LINE_CITATION_CEILING, <<~MSG
      #{bare} `path:line` citations carry no anchor, over the ceiling of
      #{UNANCHORED_LINE_CITATION_CEILING}. This number only moves DOWN.

      A bare line number says WHERE to look and nothing about what is there, so when the
      file moves it still resolves, still reads like the truth, and routes the next reader
      to whatever now sits at that offset. Lane 1 catches that only when the rot happens
      to land on a blank line or an `end`.

      Say what is on the line, in the citation itself:
      `bin/fast-check:300#"wrong_root = CertRootGuard.refusal"`. Lane 4 re-checks that on
      every run, and a slide then reds with the new line named. Better still, cite the
      SEAM (`path#symbol`) — it needs no ceiling and no anchor, because there is nothing
      left in it to rot.
    MSG
  end

  # THE FOUR DEFECTS THIS TASK WAS FILED FOR, PLUS ONE PROBE — restored verbatim and
  # driven through the REAL rules against the REAL bin/dor-check, not through a copy of
  # them. Each defect was live in this repo on 2026-09-22; three were repaired in the
  # sweep that found them, and all four are pinned here because the repairs are exactly
  # what stops the tree from proving the lanes bite. Every citation below resolves and
  # lands on a SUBSTANTIVE line, which is why the shipped guard was green on all four.
  # The fifth row is not a citation anyone wrote — see the `lanes: []` note.
  #
  # `because:` PINS THE REASON where the row has one, and on the probe row `lanes:` alone
  # is measurably not enough — see the probe's own note for the mutation that proves it.
  # Three rows carry one today; a row without it is checked on its lanes exactly as before,
  # so adding the key took no coverage away from any row that had none.
  #
  # `lanes:` IS THE FULL SET, not the first one to fire. The anchored spelling of defect A
  # trips BOTH lane 1 (its range ends on an `end`) and lane 4 (its span carries no such
  # phrase), and an earlier cut of this table recorded only the first — which would have
  # let lane 4 go silent on that row without a single assertion noticing.
  #
  # `lanes: []` IS A RECORD, NOT A TODO — AND IT TRAVELS WITH ITS PROBE. Defect D is the
  # honest floor of a resolution-keyed guard, and pinning the miss is what makes closing it
  # visible: a future lane that catches it reds HERE and asks for the row to be re-labelled,
  # rather than quietly closing a hole nobody had recorded was open. But a recorded silence
  # is only evidence while the lanes can still REACH the input, so D is followed by a PROBE
  # row — the same site with its range end pushed off the file — which must fire lane 1. The
  # two are read together or not at all: D says "the lanes are silent here", the probe says
  # "and they were listening". SIX rows: four defects across five of them — defect A is
  # pinned in two spellings, bare and anchored — and one probe. Re-derive rather than
  # re-copy; the count that shipped here said five, and review counted six.
  MISPOINTED_CITATIONS = [
    # RE-DERIVED 2026-09-24 (/tasks/dor-reads-settled-ci-verdict cut ~1,100 lines out of
    # bin/dor-check, and every row here is parsed against the REAL file). The shapes are
    # the originals; the numbers and the method names are the current tree's.
    { as_written: "bin/dor-check:1171-1175", homes: nil, lanes: [:substance],
      because: %(the range ENDS at line 1175 of bin/dor-check, a bare "end"),
      claim: "reviewers run --gate-role review from the PRIMARY",
      seen_in: "test/docs/zap_cert_freshness_docs_test.rb and test/lib/dor_check_zap_seams_test.rb",
      note: "the range ends on the bare `end` closing review_fingerprint, whose BODY the " \
            "passage has never been part of (it lives in the comment above, :1158). Lane 1 " \
            "read only the FIRST line until this task, and :1171 is a `def` — substantive, " \
            "and green for eleven days in its original spelling (:1176-1180 over " \
            "default_diff_base)." },

    { as_written: %(bin/dor-check:1171-1175#"reviewers run --gate-role review"), homes: [1158],
      because: %(the range ENDS at line 1175 of bin/dor-check, a bare "end"),
      lanes: %i[substance anchor], claim: "the same pair, spelled the way lane 5 now requires",
      seen_in: "the repair this task shipped",
      note: "the span is review_fingerprint's body and carries no such phrase. This is the " \
            "row that matters most: it is the same defect caught by CONTENT rather than by " \
            "the luck of the range having landed on an `end`." },

    { as_written: %(bin/dor-check:143#"Dor::Checks.load!"), homes: [147], lanes: [:anchor],
      claim: "bin/dor-check calls Dor::Checks.load!, a directory glob",
      seen_in: "test/lib/feature_shapes_audit_test.rb, repaired at 3c0a1179",
      note: ":143 is `require_relative \"lib/base_movement_audit\"` — substantive, four " \
            "requires away from the truth, and invisible to every resolution-only lane." },

    { as_written: %(bin/dor-check:1739#"required_meta ="), homes: [2355, 2358], lanes: [:anchor],
      claim: "`required_meta = ...` is what CI_SEAM_REQUIRE must not read as a require",
      seen_in: "test/lib/feature_shapes_audit_test.rb, repaired at 3c0a1179",
      note: ":1739 is `@review_role = review_role` — a different assignment entirely, and " \
            "616 lines from the one the sentence is about. THIS ROW IS ALSO THE LOOSE-ANCHOR " \
            "CASE: `required_meta =` is assigned twice in bin/dor-check, so the re-derivation " \
            "names both and the author is the one who has to choose. A tighter anchor is " \
            "always available (`required_meta = defaults`); the guard cannot pick it for you, " \
            "because it cannot tell a loose anchor from a file that legitimately repeats." },

    { as_written: %(bin/dor-check:33-37#"THE SUITE GATE IS THE CI VERDICT"), homes: nil, lanes: [],
      claim: "the suite gate is the settled green CI, for every shape",
      seen_in: "config/feature_shapes.yml, repaired in PR 1522 (re-sited 2026-09-24)",
      note: "DEFECT D's SHAPE, on the header that replaced the FAST-route paragraph it used " \
            "to cite (the original :44-48 CITED ITS OWN COUNTEREXAMPLE — :44-47 was the " \
            "FAST-route paragraph and :48 opened the CI-seam paragraph granting the " \
            "provisional credit the citing sentence denied; both retired with the fast route). " \
            "The range ends SUBSTANTIVE, so lane 1 is silent; the anchor is inside the span, " \
            "so lane 4 is silent — and nothing here could see a citing sentence that " \
            "contradicted the paragraph. Catching that needs the citing PROSE to be read " \
            "against the cited paragraph, which is limit A's rejected heuristic — measured " \
            "at roughly a third false." },

    # THE PROBE FOR THE ROW ABOVE. Not a citation anyone wrote — the SAME site with one
    # thing changed, and the only row here that exists to guard another row.
    { as_written: %(bin/dor-check:33-99999#"THE SUITE GATE IS THE CI VERDICT"), homes: nil, lanes: [:substance],
      because: "is outside bin/dor-check",
      claim: "THE PROBE, not a defect: the D site with its range end pushed off the file",
      seen_in: "control 5b of PR 1533's review — recorded in the report, never shipped until now",
      note: "DEFECT D IS A NEGATIVE RESULT, AND A NEGATIVE RESULT NEEDS A PROBE. `lanes: []` " \
            "passes when the lanes are genuinely silent AND when the lane machinery never " \
            "reached the input at all — an unrun test and a real miss are the same green. " \
            "This row is the same path end to end (same grammar, same target, same anchor, " \
            "same census_anchor row) with ONE difference: the range ends past the last line " \
            "of the file, so lane 1 MUST fire. If it stops firing here, D's silence above is " \
            "no longer evidence of anything, and this row says so before D can lie. Review " \
            "measured 5b red at af52ad1c; it lived in the report rather than the suite, which " \
            "is the one-level-up version of the failure this whole file exists to prevent.\n" \
            "`because:` IS NOT DECORATION ON THIS ROW — it is what makes it a probe. Measured " \
            "while building it: delete the `row[:last] > row[:size]` clause from " \
            "substance_verdict, the clause this probe exists to guard, and lane 1 STILL FIRES " \
            "— the blank-last_content branch below it catches an out-of-range end by accident, " \
            "because `at.()` returns nil past the file and nil reads as BLANK. `fired` is " \
            "[:substance] either way, so a probe pinned on lanes alone would have been GREEN on " \
            "exactly the mutation it was written for. The REASON is what separates them: " \
            "\"is outside bin/dor-check\" versus \"ENDS at line 99999 … which is BLANK\"." }
  ].freeze

  def test_the_lanes_red_every_defect_this_task_was_filed_for_and_still_reach_the_silent_one
    target = target_lines("bin/dor-check")
    refute_nil target, "bin/dor-check is the subject of all four defects, and of the probe"

    wrong = MISPOINTED_CITATIONS.filter_map do |d|
      m = LINE_CITATION.match(d[:as_written])
      next "the grammar no longer reads #{d[:as_written]}" if m.nil?

      row = census_anchor("control", m[0], m[1], m[2], m[3], target, anchor_of(m))
      verdict = substance_verdict(row)
      fired = []
      fired << :substance if verdict
      fired << :anchor if row[:anchor] && !anchor_in_span?(row)

      next "#{d[:as_written]} — expected #{d[:lanes].inspect}, fired #{fired.inspect}" if fired != d[:lanes]

      # `because:` PINS THE REASON, not just the symbol. A lane that fires for a
      # different reason than the one recorded is a rule that has changed under the row,
      # and on the probe row it is the whole point: :substance firing because the range
      # ran off the file is the reachability proof, while :substance firing because the
      # range now ends on an `end` would prove nothing about reachability at all.
      if d[:because] && !verdict.to_s.include?(d[:because])
        next "#{d[:as_written]} — lane 1 fired, but not for the recorded reason: " \
             "#{verdict.inspect} does not mention #{d[:because].inspect}"
      end

      next unless d[:homes]

      sites = anchor_sites(target, row[:anchor], row[:last] - row[:first] + 1)
      next if sites == d[:homes]

      "#{d[:as_written]} — the re-derivation named #{sites.inspect}, not #{d[:homes].inspect}"
    end

    assert_empty wrong, <<~MSG
      #{wrong.size} of the rows this guard was built from no longer behave as recorded:

      #{wrong.join("\n      ")}

      These are not fixtures. Each one is parsed by the shipping grammar and judged by the
      shipping rules against the real bin/dor-check, so a rule that goes quiet fails HERE
      rather than going quiet on the tree. If bin/dor-check has moved under a row, re-derive
      its `home` and its `note` — do not delete the row, and do not re-label a :nothing row
      as caught without saying which lane now catches it and why that lane is honest.

      IF THE FAILING ROW IS THE PROBE (`:33-99999`), read it before anything else: it is
      not a defect, it is the reachability proof for the `lanes: []` row above it. A probe
      that stops firing means the row above has stopped being evidence — its green no
      longer distinguishes "the lanes are silent here" from "the lanes never ran".
    MSG
  end

  # THE MESSAGE IS A RULE. Ask what someone would write to satisfy this lane: the cheapest
  # move is to edit the ANCHOR until it matches whatever now sits at the line — which keeps
  # the citation pointing at the wrong thing AND silences the lane that noticed. So the
  # failure must forbid that in its own words and hand over the re-derived number, which is
  # the answer the wrong move was reaching for.
  # THE VERBATIM-COPY CASE, which is how an author actually writes an anchor: they read
  # the line and copy it. On a COMMENT line that copy carries the leading marker, and
  # until this was made symmetric it could never match — `span_text` had already dropped
  # the marker from the file side. Both spellings of the same true sentence must pass,
  # or the lane reds on correct prose and its own message forbids the fix.
  def test_an_anchor_copied_verbatim_off_a_comment_line_still_matches
    target = target_lines("bin/dor-check")
    refute_nil target, "bin/dor-check is the file every recorded defect cites"

    line = target[3184].to_s.strip
    assert_match(/\A#\s/, line, "bin/dor-check:3185 is no longer a comment line — re-derive this fixture")

    stripped = line.sub(COMMENT_LEAD, "")[0, 32]
    verbatim = line[0, 34]

    row = { target: target, first: 3185, last: 3185 }
    assert anchor_in_span?(row.merge(anchor: stripped)),
           "the marker-stripped anchor #{stripped.inspect} no longer matches its own line"
    assert anchor_in_span?(row.merge(anchor: verbatim)),
           "an anchor copied VERBATIM off the cited comment line — #{verbatim.inspect} — does " \
           "not match it. That is a FALSE POSITIVE on true prose, and the lane's own message " \
           "tells the author not to edit the anchor, which is the only fix they have. Normalise " \
           "both sides the same way (see normalize_anchor)."
  end

  def test_the_anchor_failure_names_the_right_line_rather_than_inviting_a_weaker_anchor
    target = target_lines("bin/dor-check")
    m = LINE_CITATION.match(%(bin/dor-check:1171-1175#"reviewers run --gate-role review"))
    row = census_anchor("control", m[0], m[1], m[2], m[3], target, anchor_of(m))

    refute anchor_in_span?(row), "this test is anchored on :1171-1175 NOT carrying the phrase"

    message = anchor_lane_message([anchor_offender(row)])

    assert_includes message, "bin/dor-check:1158",
                    "the failure must RE-DERIVE and name the line that actually carries the " \
                    "anchor — without it the only visible fix is to weaken the anchor"
    assert_includes message, "DO NOT EDIT THE ANCHOR TO MATCH THE LINE",
                    "the cheapest way to green is the wrong one, so the message has to say so"
    assert_includes message, "SEAM",
                    "a lane that only ever teaches better line numbers is teaching the " \
                    "rotting format; the first remedy offered must be the one that cannot rot"
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

  # THE CONTINUATION SHAPES, VERBATIM, as this repo wrote them before the conversions turned
  # all three into seams. They cannot be proved by the tree any more — that is what
  # converting them means — so they are pinned here, in the file the census excludes.
  # Each pair is (the citation, the text that followed it).
  CONTINUATION_SHAPES = [
    ["bin/release.rb:224", " + :232"],
    ["bin/task:631", ", :1139"]
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

  # THE SPELLING THIS GRAMMAR DELIBERATELY CANNOT READ, and the third shape this repo once
  # wrote. `bin/statusline:229,231` was a real, CORRECT pair of anchors — and it is the same
  # string as a thousands separator, so reading it means reading `bin/release.rb:8,370` too.
  # It is pinned as a KNOWN MISS rather than deleted, because the honest record is that
  # closing the invention cost this one shape, and a future reader weighing the trade needs
  # the price in front of them. Fixing it in prose is one colon: write `:229, :231`.
  UNREAD_CONTINUATIONS = [
    [",231", "the bare comma — indistinguishable from a thousands separator"],
    [",370", "what bin/release.rb:8,370 puts after the citation"],
    [",000", "what bin/ship:100,000 puts after the citation"],
    [",2,3", "what x.rb:1,2,3 puts after the citation — it chained TWO phantom anchors"],
    [" and :3.4.1", "a version number, which minted an anchor at line 3"]
  ].freeze

  def test_the_continuation_grammar_reads_no_thousands_separator
    invented = UNREAD_CONTINUATIONS.filter_map do |tail, why|
      c = CONTINUATION_ANCHOR.match(tail)
      "#{tail.inspect} (#{why}) minted line #{c[1].to_i}" if c
    end

    assert_empty invented, <<~MSG
      #{invented.size} shape(s) this grammar must not read were parsed as a second anchor:

      #{invented.join("\n      ")}

      A comma with a number on each side is a THOUSANDS SEPARATOR as often as it is a
      continuation, and nothing in either string tells them apart. Minting an anchor from
      one is worse than missing a citation: both halves of `bin/release.rb:8,370` resolve,
      so no lane says a word while the ratchet charges two tolls for one pointer — and
      `bin/ship:100,000` reds lane 1 with "line 0 is outside bin/ship" on correct prose.
      Require the colon.
    MSG
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

  # THE WHOLE CHAIN, ON A REAL DEAD LINE — the real walk, the real row builder and the real
  # substance rule, because every one of those alone passes vacuously. `bin/ship:146` is the
  # bare `end` the rephrasing probe below is already anchored on; written as a CONTINUATION
  # it was invisible to every lane before the continuation task and is caught by all of them
  # now. It runs through `continuation_anchors` rather than matching the regex against a
  # hand-cut tail: the tail this took before was `sentence[m.end(0)..]`, the UNBOUNDED rest
  # of the string, which is not what the census offers the pattern.
  def test_a_continuation_onto_a_dead_line_is_caught
    refute_nil target_lines("bin/ship"), "bin/ship is the subject here"

    ["bin/ship:100 + :146", "bin/ship:100, :146", "bin/ship:100 and :146"].each do |sentence|
      m = LINE_CITATION.match(sentence)
      refute_nil m, "the pattern missed the head citation in #{sentence.inspect}"

      walked = continuation_anchors(sentence, m)
      assert_equal 1, walked.size, "the continuation in #{sentence.inspect} was not seen"

      text, first, last = walked.first
      assert_equal sentence, text
      row = census_anchor("fixture", text, m[1], first, last, target_lines(m[1]))
      assert_equal 146, row[:first]

      assert DELIMITER_ONLY.match?(row[:content].to_s.strip),
             "this test is anchored on bin/ship:146 being a bare delimiter; it now reads " \
             "#{row[:content].to_s.strip.inspect}, so re-anchor it on another one rather " \
             "than deleting it"
    end
  end

  # THE WALK ITSELF, DRIVEN. Everything above tests the PATTERN against a literal string;
  # this is the only test that runs `continuation_anchors` — `body[pos, WINDOW]`, the
  # `pos += c.end(0)` advance and the text slice — and until it existed those three lines
  # executed ZERO times in a green run, because the shipping tree carries no continuation
  # for the census to find. An unexercised parser inside a guard is the vacuity this whole
  # family exists to prevent.
  #
  # THE TEXT ASSERTION IS THE POINT OF THE CHAIN. Each printed text must be findable in the
  # body with a grep. Building it as `head + separator` — what this did until
  # harden-the-continuation-grammar — printed "bin/ship:1, :3" and "bin/ship:1, :4" for the
  # body below: strings that are nowhere in it, which is exactly the harm the reconstruction
  # comment says it exists to prevent.
  def test_the_continuation_walk_follows_a_chain_to_its_end
    body = "see bin/ship:1, :2, :3, :4 for the lot\n"
    m = LINE_CITATION.match(body)
    refute_nil m

    walked = continuation_anchors(body, m)

    assert_equal %w[2 3 4], walked.map { |(_t, first, _l)| first },
                 "the walk must follow the chain to its end, not stop at the first link"

    walked.each do |(text, _first, _last)|
      assert_includes body, text,
                      "#{text.inspect} is what a lane would print as the offending citation, " \
                      "and it is NOT in the body — a reader cannot grep for it and no author " \
                      "will recognise it as theirs. Slice the body; do not rebuild the string."
    end

    assert_equal ["bin/ship:1, :2", "bin/ship:1, :2, :3", "bin/ship:1, :2, :3, :4"],
                 walked.map(&:first)
  end

  # AND IT MUST STOP. Three ways: a number the grammar does not read, a newline (`[ \t]*`
  # rather than `\s*` in the pattern is what does that), and the far side of WINDOW — which
  # is the only thing keeping a continuation local to the citation it follows.
  #
  # THE LAST PAIR IS MEASURED IN WINDOWS, NOT IN CHARACTERS, deliberately: it asserts that
  # the bound is HONOURED, not that it is 48. Retuning the constant is a judgement call and
  # should not have to come here for permission. What it cannot catch is the bound being
  # REMOVED, since a fixture derived from WINDOW scales with it — so that is pinned by
  # mutation instead: `body[pos, WINDOW]` → `body[pos..]` fails this test with the full
  # 53-space gap adopted as a continuation.
  def test_the_continuation_walk_stops_at_the_windows_edge
    m = ->(body) { LINE_CITATION.match(body) }

    assert_empty continuation_anchors("bin/ship:1, 2 more follow", m.("bin/ship:1, 2 more follow")),
                 "a bare number is not an anchor, so the walk has nothing to follow"

    across = "bin/ship:1\n, :2 on the next line"
    assert_empty continuation_anchors(across, m.(across)),
                 "a continuation may not cross a newline — the citation above it is a " \
                 "different sentence in a different paragraph"

    near = "bin/ship:1#{" " * (WINDOW - 5)}, :2"
    far  = "bin/ship:1#{" " * (WINDOW + 5)}, :2"
    assert_equal 1, continuation_anchors(near, m.(near)).size,
                 "a continuation inside the window is the shape this lane exists for"
    assert_empty continuation_anchors(far, m.(far)),
                 "past WINDOW the number belongs to some other clause; adopting it would " \
                 "put a pointer in the census that continues nothing"
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
    "The refusal lives at bin/ship:146.",
    "(bin/ship:146)",
    "| caller | bin/ship:146 | discarded |",
    "See bin/ship:146 before editing.",
    "This is roughly bin/ship:146, give or take.",
    "It is recorded by bin/ship:146.",
    "Both readers (bin/ship:146) agree.",
    "bin/ship:146's comment says otherwise.",
    "[the narration seam](bin/ship:146)",
    "`bin/ship:146`",
    "bin/ship:146",
    "Do not flag this citation; it is illustrative only: bin/ship:146."
  ].freeze

  def test_no_rephrasing_hides_a_dead_pointer
    target = target_lines("bin/ship")
    refute_nil target, "bin/ship is the subject here"
    assert DELIMITER_ONLY.match?(target[145].to_s.strip),
           "this test is anchored on bin/ship:146 being a bare delimiter; it now reads " \
           "#{target[145].to_s.strip.inspect}, so re-anchor it on another one rather than deleting it"

    REPHRASINGS.each do |sentence|
      m = LINE_CITATION.match(sentence)

      refute_nil m, "the pattern missed the citation in #{sentence.inspect}"
      assert_equal "bin/ship", m[1]
      assert_equal "146", m[2]
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

          line << census_anchor(where.(m), m[0], m[1], m[2], m[3], target, anchor_of(m))

          continuation_anchors(body, m).each do |text, first, last|
            line << census_anchor(where.(m), text, m[1], first, last, target)
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

  # THE CONTINUATION WALK. Each anchor hands the next one its own end, so a chain
  # (`:10, :20, :30`) is counted to the end rather than stopping at the first. Returns
  # `[text, first, last]` per continuation, in the order the author wrote them.
  #
  # IT IS A METHOD SO A TEST CAN DRIVE IT. Inline in `census` it was unreachable except by
  # scanning the tree, and the tree carries ZERO continuations — so every green run entered
  # this loop zero times and proved nothing about it. That is this guard's own
  # exit-blindness argument turned on its newest lane, and
  # test_the_continuation_walk_follows_a_chain_to_its_end is what closes it.
  #
  # `WINDOW` is what keeps a continuation local to its citation: only the text immediately
  # after the anchor is offered, so an unrelated number further down the sentence can never
  # be adopted. `[ \t]*` rather than `\s*` in the pattern keeps it on one line as well.
  #
  # The caller runs this only INSIDE the block that has already resolved the path and
  # cleared the backtrace exemption, which is what makes the inheritance sound: a
  # continuation can never resurrect either exemption for the citation it follows. It does
  # NOT work the other way round — a continuation whose OWN tail is a backtrace frame is
  # not re-tested against BACKTRACE_FRAME, so `foo.rb:12, :118:in 'boom'` would count the
  # frame as an anchor. Nothing in this tree spells that, and Ruby never elides the path
  # between frames, so it is stated here rather than coded against.
  def continuation_anchors(body, match)
    found = []
    pos = match.end(0)

    while (c = CONTINUATION_ANCHOR.match(body[pos, WINDOW].to_s))
      pos += c.end(0)
      # THE TEXT IS A SLICE OF THE BODY, never a reconstruction. It has to be something a
      # reader can find with a grep: a bare `:232` in the failure message would send them
      # hunting for a citation written nowhere in the file, and `head + separator` — what
      # this used to build — is WORSE than bare past the first link, because
      # `see bin/ship:1, :2, :3` printed "bin/ship:1, :3", a string that is not in the body
      # at all and that no author will recognise as theirs.
      found << [body[match.begin(0)...pos], c[1], c[2]]
    end

    found
  end

  # ONE CENSUS ROW FOR ONE ANCHOR — the citation's own, or a continuation that inherited
  # its path. Deliberately identical: lanes 1 and 3 cannot tell the two apart, which is the
  # whole reason gap 1 is closed by PARSING the shape rather than by stating a limit about
  # it. A limit would have left the shape working exactly as it did.
  # A row now carries BOTH ends' content and the declared anchor, because lane 1 reads
  # the last line of a range and lane 4 reads the anchor. `target` rides along so lane 4
  # can RE-DERIVE: when an anchor is not where the citation says, the failure searches
  # the file and names the line that actually carries it.
  def census_anchor(where, text, path, first, last, target, anchor = nil)
    n = first.to_i
    e = (last || first).to_i
    at = ->(i) { target[i - 1] if i >= 1 && i <= target.size }
    { where: where, text: text, path: path, first: n, last: e, anchor: anchor,
      size: target.size, content: at.(n), last_content: at.(e), target: target }
  end

  # THE DECLARED ANCHOR, whichever of the three spellings carried it.
  def anchor_of(match) = match[4] || match[5] || match[6]

  def normalize_text(str) = str.to_s.gsub(/\s+/, " ").strip

  # AN ANCHOR IS NORMALISED THE SAME WAY THE SPAN IS, and the symmetry is the whole
  # point. `span_text` drops each line's leading comment marker, so an anchor copied
  # VERBATIM off a comment line — marker and all, which is the natural authoring
  # gesture — could never be found in it. Measured at review, 2026-09-22 against
  # bin/dor-check:3185: `#"# CI-status gate (merge gate only)"` reds while
  # `#"CI-status gate (merge gate only)"` passes, on the same true sentence. That red
  # is a FALSE POSITIVE, and the lane's own message then forbids its only fix ("DO NOT
  # EDIT THE ANCHOR TO MATCH THE LINE") and reports the text as NOWHERE while quoting
  # the span containing it. Stripping both sides costs nothing a real anchor needs:
  # `#"#!/usr/bin/env ruby"` still matches, because the span keeps its own shebang only
  # if the file line does.
  def normalize_anchor(str) = normalize_text(str.to_s.sub(COMMENT_LEAD, ""))

  # A CITED SPAN AS ONE STRING — comment markers dropped, whitespace collapsed. The span
  # is joined rather than searched line by line so an anchor may wrap a line the way the
  # sentence it came from does.
  def span_text(lines)
    normalize_text(Array(lines).map { |l| l.to_s.sub(COMMENT_LEAD, "") }.join(" "))
  end

  def anchor_in_span?(row)
    span_text(row[:target][(row[:first] - 1)..(row[:last] - 1)])
      .include?(normalize_anchor(row[:anchor]))
  end

  # WHERE THE ANCHOR ACTUALLY IS — the re-derivation that keeps lane 4's failure from
  # teaching the wrong lesson. Without it the cheapest way to go green is to rewrite the
  # ANCHOR, which preserves the rot and silences the lane forever; with it, the right
  # number is already on screen and rewriting the anchor is visibly the worse move.
  #
  # SINGLE LINES FIRST, and only then windows of the cited span's own width. Searching
  # straight at the cited width was the first cut and it was WRONG IN THE ONE WAY THAT
  # MATTERS: re-deriving `#"reviewers run --gate-role review"` from a 5-line citation
  # reported ":94, :95, :96, :97 (and 1 more)" — five window STARTS, four of which carry
  # nothing, with the one true line buried as "1 more". A message that names four innocent
  # lines is worse than one that names none, and this lane exists to hand over the right
  # number. Narrow first reports bin/dor-check:98, alone. Caught by this file's own
  # test_the_anchor_failure_names_the_right_line_rather_than_inviting_a_weaker_anchor.
  #
  # The WIDE pass is still needed and is still the cited width: an anchor may WRAP two
  # comment lines, which is how anchor_in_span? found it, so a re-derivation that could
  # only read single lines would red a citation and then report its anchor as nowhere —
  # a verdict and a diagnosis that contradict each other. Its sites are window starts,
  # which is the honest thing to report about a phrase that begins there.
  def anchor_sites(target, anchor, width)
    needle = normalize_anchor(anchor)
    narrow = (1..target.size).select { |n| span_text([target[n - 1]]).include?(needle) }
    return narrow if narrow.any? || width <= 1

    (1..target.size).select { |n| span_text(target[n - 1, width]).include?(needle) }
  end

  # LANE 1'S RULE, extracted so the control fixtures can drive the REAL one. A copy of it
  # in a fixture would pass forever while the shipping rule rotted — which is the vacuity
  # every test in this file is built to avoid.
  #
  # BOTH ENDS OF A RANGE, since 2026-09-22. Lane 1 read only the FIRST line for eleven
  # days, so `bin/dor-check:1176-1180` — a range whose last line is the bare `end` closing
  # a method the passage had long since moved out of — resolved, read as substantive and
  # sat green in two files. Measured the day the rule landed: 12 ranges in the scanned
  # corpus, and this rule flags exactly those two. A range is CUT TO FIT a passage, so a
  # block terminator at the bottom of one is the passage announcing it has moved.
  def substance_verdict(row)
    if row[:first] < 1 || row[:first] > row[:size] || row[:last] > row[:size]
      "line #{row[:first]} is outside #{row[:path]}, which has #{row[:size]} lines"
    elsif row[:content].to_s.strip.empty?
      "line #{row[:first]} of #{row[:path]} is BLANK"
    elsif DELIMITER_ONLY.match?(row[:content].to_s.strip)
      "line #{row[:first]} of #{row[:path]} is a bare #{row[:content].strip.inspect}"
    elsif row[:last] > row[:first] && row[:last_content].to_s.strip.empty?
      "the range ENDS at line #{row[:last]} of #{row[:path]}, which is BLANK"
    elsif row[:last] > row[:first] && DELIMITER_ONLY.match?(row[:last_content].to_s.strip)
      "the range ENDS at line #{row[:last]} of #{row[:path]}, a bare " \
        "#{row[:last_content].strip.inspect}"
    end
  end

  # THE LANE 4 FAILURE, extracted so a test can read what it TEACHES. A guard's message is
  # a rule in its own right: whatever it asks for is what the next person will write. The
  # cheapest way to make this lane green is to rewrite the ANCHOR — which preserves the rot
  # and silences the lane permanently — so the message has to spend its first sentence
  # forbidding that, and its re-derivation has to put the correct number on screen where
  # the wrong move would have gone.
  def anchor_lane_message(offenders)
    <<~MSG
      #{offenders.size} anchored citation(s) do not carry their anchor at the line they name:

      #{offenders.join("\n\n      ")}

      DO NOT EDIT THE ANCHOR TO MATCH THE LINE. That silences this lane and leaves the
      citation pointing exactly where it should not, which is the defect rather than the
      fix. The anchor is the half of a citation a commit cannot move — it is what the
      sentence is ABOUT. The NUMBER is what rotted, and the failure above has already
      re-derived it for you.

      Three honest fixes, in order: convert the citation to a SEAM (`path#symbol`), which
      cannot rot at all; re-point the number at the line named above; or, when the anchor
      is NOWHERE in that file, stop and decide which of two things happened — you are
      citing the wrong file, or the passage has been deleted and the sentence around the
      citation is now making a claim about nothing.
    MSG
  end

  def cited_span(row)
    text = span_text(row[:target][(row[:first] - 1)..(row[:last] - 1)])
    (text.length > 90 ? "#{text[0, 90]}…" : text).inspect
  end

  def rederivation(row)
    sites = anchor_sites(row[:target], row[:anchor], row[:last] - row[:first] + 1)
    return "the anchor is NOWHERE in #{row[:path]}" if sites.empty?

    shown = sites.first(4).map { |n| "#{row[:path]}:#{n}" }.join(", ")
    rest = sites.size > 4 ? " (and #{sites.size - 4} more — a loose anchor pins loosely)" : ""
    "the anchor IS at #{shown}#{rest}"
  end

  def anchor_offender(row)
    "#{row[:where]} cites #{row[:text]}\n" \
      "        that span reads #{cited_span(row)}\n" \
      "        #{rederivation(row)}"
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
