# frozen_string_literal: true

require "test_helper"

# [unit] WHAT RUBY ACTUALLY DOES WITH JERSEY 0 — and a tripwire so the claim that it
# does something else cannot come back.
#
# ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────────
#
# Three comments on the model-pipeline board (Appearances::LookReading twice, and
# Appearances::LookReadingTest once) asserted that `presence` or a truthiness check
# would print "no #" for the one man wearing 0, and that this was the whole reason
# #number_cell asks `nil?`. THAT WAS FALSE, and it was proved false twice during the
# review of PR 1664:
#
#   · by reading: `0.present?` is true, `0.presence` is 0, `0.blank?` is false and 0
#     is truthy, so BOTH accused checks agree with `nil?` on 0;
#   · by mutation: rewriting the guard to `if jersey_number.present?` left all 40
#     Appearances::LookReadingTest cases GREEN, so the named failure mode was not
#     reachable by any test — the comment described a trap the code could not fall into.
#
# THE CODE WAS RIGHT AND THE TEST WAS SOUND; ONLY THE JUSTIFICATION WAS WRONG, which
# is the most durable kind of error in a commented codebase: it survives every test
# run, it reads as authority, and the next author refactors TOWARD it. The real trap
# is a ZERO-MINDED check — `to_i.positive?`, `nonzero?`, `to_i > 0` — which does
# redden the suite, and which the comments never named.
#
# ── SO THE MEASUREMENT IS EXECUTABLE NOW ──────────────────────────────────────
#
# A corrected comment is worth less than a test that fails when the correction is
# undone, so this file holds both halves:
#
#   (1) THE SEMANTICS, asserted against the live runtime rather than recalled. If a
#       future ActiveSupport ever made 0 blank, these fail and the comments they back
#       become false again in the same run — which is the point.
#   (2) A PROSE TRIPWIRE over the three sites. It does not try to parse English; it
#       enforces one narrow rule that the false claim breaks and the true one does
#       not: a jersey-number comment may not accuse `presence` or truthiness WITHOUT
#       also naming the zero-minded check that is the actual trap. The false sentence
#       named only the innocent pair; the corrected one names both.
class Appearances::JerseyNumberSemanticsTest < ActiveSupport::TestCase
  # THE THREE SITES THE FALSE CLAIM OCCUPIED, by path. Named rather than globbed so a
  # file that is renamed or deleted fails loudly instead of silently leaving the guard
  # with nothing to read.
  SITES = %w[
    app/services/appearances/look_reading.rb
    app/services/appearances/pipeline.rb
    test/services/appearances/look_reading_test.rb
    test/views/model_pipeline_card_test.rb
  ].freeze

  # The innocent pair, wrongly accused.
  ACCUSED = /(?:\.presence\b|\bpresence\b|truthiness|truthy)/i
  # The check that actually breaks on 0, which an honest comment about this guard names.
  REAL_TRAP = /positive\?|nonzero\?|to_i\s*>\s*0/
  # A comment block is ABOUT the jersey guard only if it talks about the guard.
  ABOUT_THE_GUARD = /jersey|no \#|nil\?/i

  # ── (1) the semantics, measured ─────────────────────────────────────────────

  test "[unit] zero is present, not blank, and truthy — so presence does NOT misreport it" do
    assert_equal true, 0.present?, "0.present? is TRUE; `presence` would not print a gap for jersey 0"
    assert_equal 0, 0.presence, "0.presence returns 0, not nil"
    assert_equal false, 0.blank?, "0 is not blank in Ruby"
    assert_equal true, (0 ? true : false), "0 is truthy in Ruby, unlike C or JavaScript"
    refute_equal true, 0.nil?, "and `nil?` is the one predicate that separates 0 from absent"
  end

  test "[unit] the zero-minded check is the real trap, and it is the only one that differs" do
    # nil and 0 are the two inputs #number_cell must tell apart. A guard is CORRECT for
    # this cell when it answers differently for them.
    assert_equal [false, true], [0.nil?, nil.nil?], "nil? separates them — the shipped guard"
    assert_equal [true, false], [0.present?, nil.present?], "presence separates them too, by luck"
    assert_equal [false, false], [0.to_i.positive?, nil.to_i.positive?],
                 "positive? CANNOT separate them: this is the check that would print `no #` " \
                 "for the man wearing 0, and the one the comments should name"
  end

  test "[unit] the shipped cell reports 0 as a held fact and nil as the absent tone" do
    assert_equal({ key: :number, label: "#0", tone: :neutral }, cell_for(0))
    absent = cell_for(nil)
    assert_equal "no #", absent[:label]
    assert_equal :absent, absent[:tone], "absence has its own tone; a held fact keeps :neutral"
  end

  # ── (2) the prose tripwire ──────────────────────────────────────────────────

  test "[unit] no jersey comment accuses presence without naming the zero-minded check" do
    offenders = SITES.flat_map { |path| offending_blocks(path) }

    assert_empty offenders, <<~MESSAGE
      A comment about the jersey-number guard names `presence` or truthiness as the
      check that would misreport 0, without naming the check that actually would.

      THAT CLAIM IS FALSE and this file's first two tests measure why: 0.present? is
      true, 0.presence is 0, and 0 is truthy, so presence AGREES with nil? here.
      Mutating the guard to `if jersey_number.present?` leaves the whole suite green.
      The trap is a zero-minded check — to_i.positive? / nonzero? / to_i > 0.

      Name that one, or say plainly that presence happens to agree:

      #{offenders.join("\n\n")}
    MESSAGE
  end

  test "[unit] the tripwire bites — the exact sentence that shipped is caught" do
    shipped = <<~RUBY
      # 0 IS A LEGAL JERSEY, so absence is asked as
      # `nil?` — truthiness or `presence` would print "no \#" for the man wearing it.
      def number_cell
    RUBY

    assert_equal 1, blocks_in(shipped).count { |b| offending?(b) },
                 "the guard must catch the sentence it was written for"

    corrected = <<~RUBY
      # 0 IS A LEGAL JERSEY, so absence is asked as `nil?`. The check that would break
      # that is a zero-minded one — `to_i.positive?`; `presence` and truthiness agree
      # with nil? here, measured.
      def number_cell
    RUBY

    assert_empty blocks_in(corrected).select { |b| offending?(b) },
                 "and it must pass the corrected sentence, which names both"
  end

  private

  def cell_for(jersey)
    look = Appearance.new(slug: "look-jersey", person_slug: "josh-allen", descriptor: "Bills home")
    reading = Appearances::LookReading.new(appearance: look, athlete: true,
                                           athlete_team_slug: "buffalo-bills",
                                           jersey_number: jersey)
    reading.sports_facts.find { |f| f[:key] == :number }
  end

  def offending_blocks(path)
    full = Rails.root.join(path)
    assert full.exist?, "#{path} is gone; move this guard with it rather than dropping it"

    blocks_in(full.read).select { |block| offending?(block) }
               .map { |block| "#{path}:\n#{block}" }
  end

  # A BLOCK IS A RUN OF CONSECUTIVE COMMENT LINES, which is the unit a claim is made in:
  # the false sentence spanned two lines, so a line-by-line guard would see "truthiness or"
  # on one line and "would print" on the next and match neither.
  def blocks_in(source)
    source.lines.map(&:rstrip).slice_when { |a, b| a.lstrip.start_with?("#") != b.lstrip.start_with?("#") }
          .select { |run| run.first.to_s.lstrip.start_with?("#") }
          .map { |run| run.join("\n") }
  end

  def offending?(block)
    block.match?(ABOUT_THE_GUARD) && block.match?(ACCUSED) && !block.match?(REAL_TRAP)
  end
end
