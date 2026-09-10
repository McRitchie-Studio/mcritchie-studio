# frozen_string_literal: true

# [unit] The release-owned CHANGELOG roll and its guard.
#
# This output rides the commit that PRECEDES an irreversible `gem push`, so these
# tests are adversarial about the two directions that hurt: rolling a file the
# parser has misread, and refusing a file that is fine.
#
# SHAPE ONLY. No assertion below names an entry, a feature or a word of anybody's
# prose — the fixtures carry `- entry one` and nothing more — so ordinary
# changelog writing can never turn this red.
#
# THE DIALECT FIXTURES ARE TRANSCRIBED, NOT INVENTED. Each heading form below was
# read out of the real file on 2026-09-09 (`grep -E '^## '`), because the roll's
# job is to reproduce a file's OWN dialect and a fixture I made up would prove
# only that the module agrees with me:
#
#   studio-engine   ## 0.39.0 — 2026-08-11      (em dash)
#   solana-studio   ## v0.5.0 / ## v0.4.7 (2026-06-05)   (v-prefix, parens, and
#                                               the newest heading carries NO date)
#   turf-vault      ## [0.25.0] - 2026-06-10    (bracketed, hyphen)
#
#   ruby -Itest test/models/release/changelog_test.rb

require "minitest/autorun"
require "open3"
require "tmpdir"
require_relative "../../../app/models/release/changelog"

class ReleaseChangelogTest < Minitest::Test
  CL = Release::Changelog

  # A file in studio-engine's dialect: preamble, bucket, entries, two versions.
  def engine(entries: ["### Fixed", "", "- entry one"])
    lines = ["# Changelog", "", "Preamble sentence.", "", "## Unreleased", ""]
    lines += entries + [""] unless entries.empty?
    lines += ["## 0.39.0 — 2026-08-11", "", "- older entry", "",
              "## 0.38.0 — 2026-08-10", "", "- oldest entry"]
    "#{lines.join("\n")}\n"
  end

  def solana
    <<~MD
      # Changelog

      ## Unreleased

      ### Added
      - entry one

      ## v0.5.0

      - older entry

      ## v0.4.7 (2026-06-05)

      - oldest entry
    MD
  end

  def vault
    <<~MD
      # Changelog

      ## [Unreleased]

      ### Added

      - entry one

      ## [0.25.0] - 2026-06-10

      - older entry
    MD
  end

  # --- the dialect is COPIED from the file, never imposed ----------------------

  def test_each_measured_dialect_round_trips_into_the_next_heading
    assert_equal "## 0.40.0 — 2026-09-09", CL.heading_for("0.40.0", "2026-09-09", CL.dialect(engine))
    assert_equal "## v0.6.0 (2026-09-09)", CL.heading_for("0.6.0", "2026-09-09", CL.dialect(solana))
    assert_equal "## [0.26.0] - 2026-09-09", CL.heading_for("0.26.0", "2026-09-09", CL.dialect(vault))
  end

  # solana-studio's NEWEST heading (`## v0.5.0`) carries no date while its
  # neighbours do. Reading the date form off the newest heading alone would drop
  # the date from every future heading in that repo — silently, and forever.
  def test_the_date_form_comes_from_the_newest_DATED_heading
    assert_equal :parens, CL.dialect(solana)[:date]
    assert CL.dialect(solana)[:v_prefix], "the v-prefix comes from the newest heading, dated or not"
  end

  # A file whose headings are ALL undated keeps its dialect: no date is invented.
  def test_a_file_with_no_dated_heading_keeps_writing_undated_headings
    text = "# Changelog\n\n## Unreleased\n\n- entry one\n\n## 0.2.0\n\n- older entry\n"

    assert_equal "## 0.3.0", CL.heading_for("0.3.0", "2026-09-09", CL.dialect(text))
  end

  # No version heading at all — a gem's first release — has no dialect to copy,
  # so it falls back to the ecosystem's canonical modern form.
  def test_a_first_release_falls_back_to_the_canonical_form
    text = "# Changelog\n\n## Unreleased\n\n- entry one\n"

    assert_equal "## 0.1.0 — 2026-09-09", CL.heading_for("0.1.0", "2026-09-09", CL.dialect(text))
  end

  # --- the roll ----------------------------------------------------------------

  def test_the_roll_moves_the_bucket_under_a_new_heading_and_leaves_it_empty
    rolled = CL.roll(engine, version: "0.40.0", date: "2026-09-09")
    headings = CL.headings(rolled).map { |h| h[:line] }

    assert_equal ["## Unreleased", "## 0.40.0 — 2026-09-09", "## 0.39.0 — 2026-08-11", "## 0.38.0 — 2026-08-10"],
                 headings, "the bucket stays first and the new heading goes directly beneath it"
    assert_empty CL.unreleased_entries(rolled), "the bucket must be empty and ready for the next cycle"
  end

  # The entries must arrive under the new heading BYTE FOR BYTE and in order. A
  # roll that reflowed, re-indented or reordered anybody's prose would be a worse
  # defect than the one this fixes.
  def test_the_entries_arrive_verbatim_under_the_new_heading
    entries = ["### Fixed", "", "- entry one", "  continued, indented", "", "### Added", "", "- entry two"]
    rolled  = CL.roll(engine(entries: entries), version: "0.40.0", date: "2026-09-09")
    lines   = rolled.lines.map(&:chomp)
    start   = lines.index("## 0.40.0 — 2026-09-09")
    finish  = lines.index("## 0.39.0 — 2026-08-11")

    assert start && finish && start < finish
    assert_equal entries, lines[(start + 1)...finish].drop_while { |l| l.strip.empty? }
                                                     .reverse.drop_while { |l| l.strip.empty? }.reverse
  end

  # NOTHING OUTSIDE THE BUCKET MOVES. Asserted as a whole-file property rather
  # than by spot-checking lines: everything the roll did not add must still be
  # there, in the same order.
  def test_the_roll_adds_a_heading_and_changes_nothing_else
    before = engine.lines.map(&:chomp).reject { |l| l.strip.empty? }
    after  = CL.roll(engine, version: "0.40.0", date: "2026-09-09").lines.map(&:chomp).reject { |l| l.strip.empty? }

    assert_equal ["## 0.40.0 — 2026-09-09"], after - before
    assert_empty before - after, "the roll must not drop a single line"
  end

  # An empty bucket still earns its heading. That is what keeps "the newest
  # heading names the newest published version" exact, and it is what makes a
  # release that documented nothing VISIBLE rather than a silent gap.
  def test_an_empty_bucket_still_gets_its_heading
    rolled = CL.roll(engine(entries: []), version: "0.40.0", date: "2026-09-09")

    assert_equal ["## Unreleased", "## 0.40.0 — 2026-09-09", "## 0.39.0 — 2026-08-11", "## 0.38.0 — 2026-08-10"],
                 CL.headings(rolled).map { |h| h[:line] }
    assert_empty CL.unreleased_entries(rolled)
  end

  def test_the_roll_declines_a_file_with_no_bucket
    assert_nil CL.roll("# Changelog\n\n## 0.39.0 — 2026-08-11\n\n- older entry\n",
                       version: "0.40.0", date: "2026-09-09")
  end

  def test_the_roll_preserves_the_other_dialects_too
    assert_includes CL.roll(solana, version: "0.6.0", date: "2026-09-09"), "## v0.6.0 (2026-09-09)"
    assert_includes CL.roll(vault, version: "0.26.0", date: "2026-09-09"), "## [0.26.0] - 2026-09-09"
  end

  # --- the guard ---------------------------------------------------------------

  def test_a_healthy_file_is_not_refused
    assert_nil CL.refusal(engine, published_version: "0.39.0")
    assert_nil CL.refusal(engine, published_version: "0.40.1"), "one minor of drift is within tolerance"
  end

  def test_nothing_published_yet_is_never_refused
    assert_nil CL.refusal(engine, published_version: nil)
    assert_nil CL.refusal(engine, published_version: "")
  end

  # THE ASSERTION THAT BITES. studio-engine's real numbers on 2026-09-09.
  def test_a_backlog_is_refused_and_the_refusal_names_the_drift
    message = CL.refusal(engine, published_version: "0.74.4")

    refute_nil message
    assert_includes message, "BACKLOG"
    assert_includes message, "35 minor version(s)"
    assert_includes message, "0.39.0"
    assert_includes message, "0.74.4"
    assert_includes message, "NOTHING has been published"
  end

  # THE CONTROL, and it is the reason this file does not ship an order check.
  # MEASURED on the real 2,382-line file: its version headings were already in
  # strictly decreasing order, because the defect was everything filed ABOVE them.
  # An order assertion here would be GREEN on the fully broken file — a guard
  # proving nothing. This test pins that fact so nobody re-derives it, and pairs
  # it with the assertion that DOES bite.
  def test_the_ordering_property_is_green_on_the_very_file_the_guard_refuses
    text     = engine
    ordered  = CL.versions(text).map { |h| h[:version] }

    assert_equal ordered.sort.reverse, ordered, "an order check passes on this file..."
    refute_nil CL.refusal(text, published_version: "0.74.4"), "...while the drift check refuses it"
  end

  # A major behind is the same defect at a louder scale, and it must not be
  # reported as a nonsense minor count.
  def test_a_whole_major_behind_is_refused_without_inventing_a_minor_count
    message = CL.refusal(engine, published_version: "1.4.0")

    assert_includes message, "a whole major version"
    refute_includes message, "minor version(s)"
  end

  # A backlog with an EMPTY bucket has no history to mis-file, so it must not
  # hold the sweep. This is the half that keeps the guard aimed at the harm
  # rather than at the number.
  def test_a_backlog_with_an_empty_bucket_is_not_refused
    assert_nil CL.refusal(engine(entries: []), published_version: "0.74.4")
  end

  def test_a_heading_ahead_of_what_shipped_is_refused
    message = CL.refusal(engine, published_version: "0.38.0")

    assert_includes message, "AHEAD"
    assert_includes message, "documented before it shipped"
  end

  # --- the parse floor, DERIVED rather than counted ----------------------------
  #
  # A guard that carries a hard-coded heading COUNT is tuned to one repo's
  # history. Copied into a repo with fewer headings that number can never fire
  # and the guard passes VACUOUSLY — the exact failure the floor was added to
  # prevent, reproduced by the act of reuse. So the floor here is a PROPERTY:
  # every '## ' heading below the bucket must PARSE. The two tests below make that
  # claim real — the same broken dialect is caught in a 2-heading file and in a
  # 200-heading one, because no count is consulted.

  def test_an_unparseable_heading_is_refused_not_skipped
    text = "# Changelog\n\n## Unreleased\n\n- entry one\n\n## Release 0.39.0\n\n- older entry\n"
    message = CL.refusal(text, published_version: "0.74.4")

    assert_includes message, "parse as neither a version nor the Unreleased bucket"
    assert_includes message, "Release 0.39.0", "the refusal must name the line it could not read"
  end

  def test_the_floor_is_a_property_so_file_size_cannot_defeat_it
    small = "# Changelog\n\n## Unreleased\n\n- entry one\n\n## Release 0.39.0\n\n- x\n"
    big   = "# Changelog\n\n## Unreleased\n\n- entry one\n\n" +
            (200.downto(1).map { |n| "## Release 0.#{n}.0\n\n- x\n" }.join("\n"))

    [small, big].each do |text|
      assert_includes CL.refusal(text, published_version: "0.74.4").to_s,
                      "parse as neither a version nor the Unreleased bucket",
                      "a count-based floor would pass one of these; a property-based one passes neither"
    end
  end

  def test_a_published_gem_whose_changelog_names_no_version_is_refused
    text = "# Changelog\n\n## Unreleased\n\n- entry one\n"

    assert_includes CL.refusal(text, published_version: "0.74.4"), "names no version at all"
  end

  # --- the bucket's own invariants ---------------------------------------------

  def test_a_file_with_no_headings_is_refused
    assert_includes CL.refusal("# Changelog\n\njust prose\n", published_version: "0.74.4"),
                    "no '## ' headings at all"
  end

  def test_a_missing_bucket_is_refused
    text = "# Changelog\n\n## 0.39.0 — 2026-08-11\n\n- older entry\n"

    assert_includes CL.refusal(text, published_version: "0.39.0"), "no '## Unreleased' heading"
  end

  def test_a_bucket_that_is_not_first_is_refused
    text = "# Changelog\n\n## 0.39.0 — 2026-08-11\n\n- older\n\n## Unreleased\n\n- entry one\n"

    assert_includes CL.refusal(text, published_version: "0.39.0"), "is not the first '## ' heading"
  end

  def test_two_buckets_are_refused_rather_than_guessed_between
    text = "# Changelog\n\n## Unreleased\n\n- a\n\n## [Unreleased]\n\n- b\n\n## 0.39.0 — 2026-08-11\n\n- older\n"

    assert_includes CL.refusal(text, published_version: "0.39.0"), "refusing to guess which one is live"
  end

  # turf-vault carries a FROZEN `## [Unreleased] - 2026-05-18 (post-v0.11.0)`
  # heading mid-file. A prefix-matching bucket regex would read it as a second
  # live bucket; an anchored one reads it as an unparseable heading and says so.
  # Either way it must not be silently ignored — this pins which answer we give.
  def test_a_historical_dated_unreleased_heading_is_reported_not_ignored
    text = "# Changelog\n\n## [Unreleased]\n\n- entry one\n\n## [0.25.0] - 2026-06-10\n\n- older\n\n" \
           "## [Unreleased] - 2026-05-18 (post-v0.11.0)\n\n- frozen\n"

    assert_includes CL.refusal(text, published_version: "0.25.0"),
                    "parse as neither a version nor the Unreleased bucket"
  end


  # --- fenced code blocks are CONTENT, not structure ---------------------------
  #
  # REPRODUCED 2026-09-09 against published 0.74.4. A builder documenting this
  # very change writes an entry under `## Unreleased` quoting the heading the roll
  # writes, inside a ```markdown fence. Before fence awareness:
  #
  #   refusal()            => nil            — the guard was BLIND
  #   unreleased_entries() =>  5 of 14 lines
  #   roll()               => a blank line injected INSIDE the fence, and every
  #                           entry below it (the trailing bullet and the whole
  #                           `### Docs` section) filed under `## 0.74.4`, a
  #                           version that had already shipped.
  #
  # It is blind exactly where it matters: the drift guard fails closed only
  # OUTSIDE MAX_MINOR_DRIFT, so a fenced 0.74.4 / 0.74.2 / 0.72.0 all passed
  # silently while only 0.60.0 hit BACKLOG. Quoting a RECENT heading — the likely
  # case — was the one that slipped through. And the rolled file rides the same
  # commit as version_file + Gemfile.lock onto origin/release BEFORE `gem push`,
  # so the artifact and its v* tag would carry the mis-filed history.
  #
  # THE FORK, and it was a real one: IGNORE a fenced `## ` as content, or REFUSE a
  # bucket that contains one. This picks IGNORE for a TERMINATED fence and REFUSE
  # for an UNTERMINATED one — which is not two policies but the module's existing
  # one, applied twice. A terminated fence is UNAMBIGUOUS: CommonMark, GitHub's
  # renderer and every human reader agree the line is literal text, so ignoring it
  # is the CORRECT parse and refusing would refuse a file that is fine — the
  # second of the two directions this file is adversarial about. An UNTERMINATED
  # fence is genuinely undecidable: a renderer reads the rest of the file as code,
  # so "where does the bucket end" has no honest answer. That is the same
  # condition the unparseable-heading refusal already fires on.

  # The 14-line body from the reproduction. `open`/`close` are the delimiters
  # under test and `indent` the content's column, so one fixture drives every
  # fence dialect the ecosystem can write.
  def documented(open: "```markdown", close: "```", indent: "")
    ["### Fixed", "",
     "- prepare now rolls the bucket. The heading it writes:", "",
     open,
     "#{indent}## 0.74.4 — 2026-09-09",
     close, "",
     "- and a trailing bullet", "",
     "### Docs", "",
     "- documented the roll",
     "- and the guard"]
  end

  # (a) The whole bucket is read — all 14 lines, verbatim. Pre-fix: 5.
  def test_a_fenced_heading_is_content_so_the_whole_bucket_is_read
    body = documented

    assert_equal 14, body.size, "the fixture is the reproduction's 14 lines"
    assert_equal body, CL.unreleased_entries(engine(entries: body)),
                 "a '## ' inside a fence is literal text; it cannot cut the section short"
  end

  # (b) Every entry lands under the NEW heading, and nothing is written inside the
  # fence. Asserted byte-for-byte, because the pre-fix failure was a single blank
  # line injected between the fence's opener and its content — invisible to any
  # assertion that filters blanks.
  def test_the_roll_files_every_fenced_entry_under_the_new_heading
    body   = documented
    rolled = CL.roll(engine(entries: body), version: "0.74.5", date: "2026-09-09")
    lines  = rolled.lines.map(&:chomp)
    start  = lines.index("## 0.74.5 — 2026-09-09")
    finish = lines.index("## 0.39.0 — 2026-08-11")

    assert_equal ["## Unreleased", "## 0.74.5 — 2026-09-09", "## 0.39.0 — 2026-08-11", "## 0.38.0 — 2026-08-10"],
                 CL.headings(rolled).map { |h| h[:line] },
                 "the quoted heading must not become a section of its own"
    assert start && finish && start < finish
    assert_equal body, lines[(start + 1)...finish].drop_while { |l| l.strip.empty? }
                                                  .reverse.drop_while { |l| l.strip.empty? }.reverse,
                 "the fence arrives intact: nothing injected inside it, nothing left behind it"
    assert_empty CL.unreleased_entries(rolled), "and the bucket is empty and ready for the next cycle"
  end

  # Every fence dialect a builder can write. The INDENTED row is the one that
  # corrects a tempting half-truth: an indented fence is safe only while its
  # CONTENT is indented too. A fence opened at column 2 around a heading at
  # column 0 is a valid fenced block whose inner line matches the anchored
  # heading regex exactly.
  def test_every_fence_dialect_is_recognised
    {
      "backtick" => { open: "```markdown", close: "```" },
      "tilde" => { open: "~~~markdown", close: "~~~" },
      "bare backtick" => { open: "```", close: "```" },
      "indented opener, column-0 content" => { open: "  ```markdown", close: "  ```" },
      "longer opener" => { open: "````markdown", close: "````" }
    }.each do |label, delims|
      body = documented(**delims)

      assert_equal body, CL.unreleased_entries(engine(entries: body)), "#{label}: the bucket must read whole"
      refute_includes CL.headings(engine(entries: body)).map { |h| h[:line] }, "## 0.74.4 — 2026-09-09",
                      "#{label}: the fenced line must not be counted as a heading"
    end
  end

  # WHAT DOES NOT CLOSE A FENCE. Each row below is a delimiter-looking line that
  # a looser reader would treat as the close, putting the heading beneath it back
  # outside the fence and reopening the defect. All three were reached by mutating
  # the closing rule and watching the suite stay green, so each one is here
  # because its absence was measured, not imagined.
  def test_only_a_matching_delimiter_closes_a_fence
    {
      "a shorter run" => ["````markdown", "```", "## 0.74.4 — 2026-08-01", "````"],
      "the other delimiter character" => ["```markdown", "~~~", "## 0.74.4 — 2026-08-01", "```"],
      "a run carrying an info string" => ["```markdown", "```ruby", "## 0.74.4 — 2026-08-01", "```"]
    }.each do |label, fence|
      body = ["### Fixed", ""] + fence + ["", "- a trailing bullet"]

      assert_equal body, CL.unreleased_entries(engine(entries: body)), "#{label}: must not close the fence"
      refute_includes CL.headings(engine(entries: body)).map { |h| h[:line] }, "## 0.74.4 — 2026-08-01",
                      "#{label}: the heading below it is still inside the fence"
    end
  end

  # A BACKTICK FENCE'S INFO STRING MAY NOT CONTAIN A BACKTICK — CommonMark's rule,
  # and the reason is that such a line is ordinary text rather than a fence. Read
  # as an opener it would open a block nothing ever closes, and this module would
  # then REFUSE a perfectly good changelog.
  def test_a_backtick_run_whose_info_string_holds_a_backtick_is_not_a_fence
    body = ["### Fixed", "",
            "```js`x",
            "- an ordinary line that merely starts with backticks"]

    assert_nil CL.refusal(engine(entries: body), published_version: "0.39.0"),
               "a non-fence must not be reported as an unterminated one"
    assert_equal body, CL.unreleased_entries(engine(entries: body))
  end

  # THE BUCKET INDEX IS FENCE-AWARE TOO, and this is the case that proves the two
  # halves share one scan. A changelog whose PREAMBLE shows the format quotes
  # `## Unreleased` above the real bucket. `refusal` reads headings (fence-aware
  # from the start) and sees one bucket; a `roll` that indexed the first RAW match
  # would cut at the quoted one instead — the guard and the write looking at two
  # different files, immediately before an irreversible push.
  def test_a_quoted_bucket_above_the_real_one_is_not_the_bucket
    text = ["# Changelog", "",
            "The bucket this file keeps:", "",
            "```markdown",
            "## Unreleased",
            "```", "",
            "## Unreleased", "",
            "- entry one", "",
            "## 0.39.0 — 2026-08-11", "",
            "- older entry"].join("\n") + "\n"

    assert_nil CL.refusal(text, published_version: "0.39.0"), "the quoted bucket is not a second bucket"
    assert_equal ["- entry one"], CL.unreleased_entries(text),
                 "the entries come from the REAL bucket, not the quoted one"
    assert_includes CL.roll(text, version: "0.40.0", date: "2026-09-09"),
                    "## 0.40.0 — 2026-09-09\n\n- entry one"
  end

  # A fence closes only on a delimiter at least as long as its opener, in the same
  # character — so a ``` line inside a ```` block is content, and the heading
  # after it is still inside the fence. Getting this wrong reopens the defect for
  # exactly the file that quotes a fence inside a fence: this changelog entry.
  def test_a_longer_fence_is_not_closed_by_a_shorter_delimiter
    body = ["### Fixed", "",
            "````markdown",
            "```ruby",
            "## 0.74.4 — 2026-09-09",
            "```",
            "````", "",
            "- a trailing bullet"]

    assert_equal body, CL.unreleased_entries(engine(entries: body))
    refute_includes CL.headings(engine(entries: body)).map { |h| h[:line] }, "## 0.74.4 — 2026-09-09"
  end

  # The bucket regex scans for `## ` too, so fence blindness cut BOTH ways: a
  # quoted `## Unreleased` was read as a second live bucket. Worse, `refusal`
  # counted buckets while `roll` indexed the FIRST one, so the two halves could
  # disagree about which file they were looking at. One fence map now feeds both.
  def test_a_fenced_unreleased_heading_is_not_read_as_a_second_bucket
    body = ["### Fixed", "",
            "- the bucket this module leaves behind:", "",
            "```markdown",
            "## Unreleased",
            "```", "",
            "- a trailing bullet"]
    text = engine(entries: body)

    assert_nil CL.refusal(text, published_version: "0.39.0"), "one live bucket, quoted or not"
    assert_equal body, CL.unreleased_entries(text)
  end

  # THE REFUSING HALF OF THE FORK. An unterminated fence has no honest reading —
  # a renderer treats the rest of the file as code — so this refuses rather than
  # pick one, and names the line so the fix is a one-line edit rather than a hunt.
  def test_an_unterminated_fence_is_refused_rather_than_guessed_at
    body = ["### Fixed", "",
            "```markdown",
            "## 0.74.4 — 2026-09-09", "",
            "- a bullet whose fence was never closed"]
    text    = engine(entries: body)
    opener  = text.lines.map(&:chomp).index("```markdown") + 1
    message = CL.refusal(text, published_version: "0.39.0")

    refute_nil message, "an undecidable parse must not roll"
    assert_includes message, "unterminated"
    assert_includes message, "line #{opener}",
                    "the refusal must name the opener it could not find a close for"
  end

  # (c) THE GUARD STILL BITES. This is the assertion Carl's reproduction turned
  # red: with the fenced 0.74.4 read as a heading the drift measured 0 and the
  # BACKLOG guard returned nil — blind on the very file it exists to refuse.
  def test_fence_awareness_does_not_blunt_the_backlog_and_ahead_guards
    text = engine(entries: documented)

    assert_includes CL.refusal(text, published_version: "0.74.4").to_s, "BACKLOG",
                    "the quoted heading must not be credited as documenting 0.74.4"
    assert_includes CL.refusal(text, published_version: "0.74.4").to_s, "35 minor version(s)"
    assert_includes CL.refusal(text, published_version: "0.38.0").to_s, "AHEAD"
    assert_nil CL.refusal(text, published_version: "0.39.0"), "and a healthy file with a fence still rolls"
  end

  # --- entry detection ---------------------------------------------------------

  def test_entries_are_detected_only_when_the_bucket_holds_something
    assert CL.entries?(engine)
    refute CL.entries?(engine(entries: []))
    refute CL.entries?("# Changelog\n\n## 0.39.0 — 2026-08-11\n\n- older\n"), "no bucket means no entries"
  end

  # --- the misfile guard: a merge across a roll ---------------------------------
  #
  # THE DEFECT, measured 2026-09-10 on studio-engine's real CHANGELOG with the real
  # roll (/tasks/rolled-changelog-merge-misfiles). The roll lands on `release` only;
  # `accepted` keeps the un-rolled bucket until something merges the release commit
  # back. So the next promote three-way-merges an un-rolled bucket into a rolled
  # file, and git merges a bullet added INSIDE an existing `###` subsection CLEANLY
  # — straight under the heading the roll just wrote, a version that shipped
  # without it. Nothing fails, and the next roll moves only what sits under
  # `## Unreleased`, so the entry stays mis-filed for good.
  #
  # These tests rebuild that merge with REAL `git merge-file`, so they exercise
  # git's actual placement rather than a hand-written guess at it.

  PUBLISHED = "0.40.0"

  def merge_file(ours, base, theirs)
    Dir.mktmpdir("changelog-merge") do |dir|
      paths = { "ours" => ours, "base" => base, "theirs" => theirs }.to_h do |name, text|
        path = File.join(dir, name)
        File.write(path, text)
        [name, path]
      end
      out, status = Open3.capture2("git", "merge-file", "-p", paths["ours"], paths["base"], paths["theirs"])
      [out, status.exitstatus]
    end
  end

  # base: the bucket the promote forked from. release: that base, rolled and
  # published as 0.40.0 (the file at tag v0.40.0). accepted: the same base plus one
  # bullet written after the roll, inside the existing `### Fixed`.
  def across_a_roll
    base     = engine
    release  = CL.roll(base, version: PUBLISHED, date: "2026-09-11")
    accepted = engine(entries: ["### Fixed", "", "- entry two", "- entry one"])
    merged, status = merge_file(release, base, accepted)
    [release, merged, status]
  end

  def section_of(text, line)
    CL.headings(text).select { |h| h[:number] < text.lines.index { |l| l.chomp == line }.to_i + 1 }.last[:line]
  end

  # The precondition, pinned so a future git cannot quietly make this suite vacuous:
  # the merge really is CLEAN, and the new bullet really lands under the release.
  def test_git_merges_a_bullet_across_a_roll_cleanly_under_the_published_heading
    _release, merged, status = across_a_roll

    assert_equal 0, status, "git merge-file must merge this CLEAN — that is what makes the misfile silent"
    assert_equal "## #{PUBLISHED} — 2026-09-11", section_of(merged, "- entry two"),
                 "the bullet written after the release must land under the release's own heading"
  end

  def misfiled(merged, sides:, published: [PUBLISHED])
    CL.misfiled_entries(merged, base: engine, sides: sides, published: published)
  end

  def test_a_bullet_merged_under_a_published_heading_is_named_as_misfiled
    release, merged, = across_a_roll
    accepted = engine(entries: ["### Fixed", "", "- entry two", "- entry one"])

    found = misfiled(merged, sides: [release, accepted])

    assert_equal [[PUBLISHED, "- entry two"]], found.map { |m| [m[:version], m[:line]] }
    refusal = CL.misfile_refusal(merged, base: engine, sides: [release, accepted], published: [PUBLISHED])
    assert_includes refusal.to_s, "- entry two", "the refusal must name the mis-filed line"
    assert_includes refusal.to_s, PUBLISHED, "and the shipped version it landed under"
    assert_includes refusal.to_s, "NOTHING was promoted"
  end

  # The control: the same bullet, merged by an `accepted` that already carries the
  # roll, sits in the bucket where it belongs.
  def test_the_same_bullet_under_unreleased_is_not_a_misfile
    release, = across_a_roll
    healthy = release.sub("## Unreleased\n\n", "## Unreleased\n\n### Fixed\n\n- entry two\n\n")

    assert_empty misfiled(healthy, sides: [release, healthy])
    assert_nil CL.misfile_refusal(healthy, base: engine, sides: [release, healthy], published: [PUBLISHED])
  end

  # A re-run after an abort between the version commit and its tag ships the
  # promoted work IN that version, so landing under it is correct until it has a tag.
  def test_a_line_under_a_version_not_yet_published_is_not_judged
    release, merged, = across_a_roll
    accepted = engine(entries: ["### Fixed", "", "- entry two", "- entry one"])

    assert_empty misfiled(merged, sides: [release, accepted], published: [])
  end

  # THE FALSE POSITIVE THAT SHAPED THIS RULE. Published entries get reworded after
  # release here, on purpose (solana-studio's 0.4.0, studio-engine's 0.36.0 and
  # 0.37.0 on 2026-09-10). An edit to a shipped section is not a bucket addition.
  def test_rewording_a_shipped_entry_is_not_a_misfile
    release = CL.roll(engine, version: PUBLISHED, date: "2026-09-11")
    reworded = release.sub("- entry one\n", "- entry one, reworded after release\n")

    assert_empty CL.misfiled_entries(reworded, base: release, sides: [release, reworded], published: [PUBLISHED])
  end

  # Moving a SHIPPED entry out of the bucket and under its version is the documented
  # hand attribution (studio-engine docs/RELEASE.md): the bucket LOSES a line.
  def test_a_line_moved_out_of_the_bucket_is_attribution_not_a_misfile
    before = engine(entries: ["- shipped late"])
    after = before.sub("## Unreleased\n\n- shipped late\n\n", "## Unreleased\n\n")
                  .sub("## 0.39.0 — 2026-08-11\n\n", "## 0.39.0 — 2026-08-11\n\n- shipped late\n")

    assert_empty CL.misfiled_entries(after, base: before, sides: [before, after], published: ["0.39.0"])
  end
end
