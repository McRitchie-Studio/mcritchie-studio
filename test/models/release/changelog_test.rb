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
  # studio-engine's own guard carries MIN_VERSION_HEADINGS = 110 against a real
  # 115. Copied into a repo with eleven headings that number can never fire and
  # the guard passes VACUOUSLY — the exact failure the floor was added to prevent,
  # reproduced by the act of reuse. So the floor here is a PROPERTY: every '## '
  # heading below the bucket must PARSE. The two tests below are what make that
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

  # --- entry detection ---------------------------------------------------------

  def test_entries_are_detected_only_when_the_bucket_holds_something
    assert CL.entries?(engine)
    refute CL.entries?(engine(entries: []))
    refute CL.entries?("# Changelog\n\n## 0.39.0 — 2026-08-11\n\n- older\n"), "no bucket means no entries"
  end
end
