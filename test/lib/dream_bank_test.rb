# frozen_string_literal: true

# Tests for bin/lib/dream_bank.rb — the parser and formatter behind the dream
# bank (docs/agents/dreams/), which bin/session-insights loads at session start.
#   ruby -Itest test/lib/dream_bank_test.rb
#
#   [unit] parse, the approved filter and the context block, on fixture text.
#   [unit] the REAL bank: every tracked dream parses, and none is malformed. A
#          dream that fails to parse loads nowhere and says nothing, so this is
#          the only place a typo in a dream's frontmatter becomes visible.

require "minitest/autorun"
require "tmpdir"
require_relative "../../bin/lib/dream_bank"

class DreamBankTest < Minitest::Test
  DREAM = <<~MD
    ---
    question: "Do I merge on one read?"
    answer: "No.
      Wait for the report."
    why: "A late blocker costs a whole task."
    status: Approved
    source: "2026-09-23"
    ---

    # Wait for it

    ## Situation
  MD

  def test_unit_parse_reads_the_four_fields_and_folds_whitespace
    dream = DreamBank.parse(DREAM, slug: "wait-for-it")

    assert_equal "wait-for-it", dream.slug
    assert_equal "Do I merge on one read?", dream.question
    assert_equal "No. Wait for the report.", dream.answer
    assert_equal "A late blocker costs a whole task.", dream.why
    assert dream.approved?, "status is matched case-insensitively"
  end

  def test_unit_parse_refuses_text_with_nothing_to_teach
    assert_nil DreamBank.parse("# no frontmatter", slug: "x")
    assert_nil DreamBank.parse("---\nquestion: \"only a question\"\nstatus: approved\n---\n", slug: "x")
    assert_nil DreamBank.parse("---\n: : not yaml [\n---\n", slug: "x")
    assert_nil DreamBank.parse("---\n- a list\n---\n", slug: "x")
  end

  def test_unit_a_dream_without_a_status_is_not_approved
    dream = DreamBank.parse("---\nquestion: \"Q?\"\nanswer: \"A.\"\n---\n", slug: "x")

    refute dream.approved?, "approval is explicit; a missing status must not load"
  end

  def test_unit_context_renders_only_approved_dreams
    approved = DreamBank.parse(DREAM, slug: "wait-for-it")
    proposed = DreamBank.parse(DREAM.sub("Approved", "proposed").sub("Do I merge", "Should I merge"), slug: "later")

    context = DreamBank.context([ proposed, approved ])

    assert_includes context, "## Dreams"
    assert_includes context, "**Q: Do I merge on one read?** (`wait-for-it`)\nA: No. Wait for the report.\n" \
                             "Why: A late blocker costs a whole task."
    refute_includes context, "Should I merge"
  end

  def test_unit_context_is_empty_when_nothing_is_approved
    proposed = DreamBank.parse(DREAM.sub("Approved", "proposed"), slug: "later")

    assert_equal "", DreamBank.context([ proposed ])
    assert_equal "", DreamBank.context([])
  end

  def test_unit_all_reads_a_directory_in_order_and_skips_the_readme
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "b-second.md"), DREAM)
      File.write(File.join(dir, "a-first.md"), DREAM.sub("Approved", "proposed"))
      File.write(File.join(dir, "README.md"), DREAM)
      File.write(File.join(dir, "broken.md"), "no frontmatter here")

      assert_equal %w[a-first b-second], DreamBank.all(dir: dir).map(&:slug)
      assert_equal %w[b-second], DreamBank.approved(dir: dir).map(&:slug)
    end
  end

  def test_unit_a_missing_directory_is_an_empty_bank
    assert_equal [], DreamBank.all(dir: "/nonexistent-dream-bank")
  end

  # ── the real bank ──────────────────────────────────────────────────────────

  def test_unit_every_tracked_dream_parses_with_a_known_status
    files = Dir.glob(File.join(DreamBank::DEFAULT_DIR, "*.md")).reject { |p| File.basename(p) == "README.md" }
    dreams = DreamBank.all

    refute_empty files, "the bank has no dreams; DEFAULT_DIR may point at the wrong place"
    assert_equal files.map { |p| File.basename(p, ".md") }.sort, dreams.map(&:slug),
                 "a dream file failed to parse, so it would load nowhere and say nothing"
    dreams.each do |dream|
      assert_includes %w[proposed approved], dream.status, "#{dream.slug} has an unknown status"
      refute_empty dream.why, "#{dream.slug} gives no reason; a dream without its why is a rule"
    end
  end
end
