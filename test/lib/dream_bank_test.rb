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
require "fileutils"
require "stringio"
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

  # ── the budget: degrade on purpose, never silently ─────────────────────────

  def three_dreams
    %w[one two three].map { |slug| DreamBank.parse(DREAM, slug: slug) }
  end

  def test_unit_context_drops_the_why_lines_before_it_drops_a_dream
    full = DreamBank.context(three_dreams)
    brief = DreamBank.context(three_dreams, budget: full.size - 1)

    assert_includes full, "Why: A late blocker"
    refute_includes brief, "Why:"
    assert_equal 3, brief.scan(/^\*\*Q:/).size, "every dream survives the first degrade"
    assert_operator brief.size, :<, full.size
  end

  def test_unit_context_over_budget_keeps_whole_dreams_and_says_how_many_it_left_out
    brief = DreamBank.render(three_dreams, why: false)
    context = DreamBank.context(three_dreams, budget: brief.size - 1)

    assert_operator context.size, :<=, brief.size - 1, "the block never exceeds its budget"
    assert_operator context.scan(/^\*\*Q:/).size, :<, 3
    assert_match(/\*\*[12] more approved dream\(s\) did not fit this block\.\*\*/, context)
    assert_includes context, "Read `docs/agents/dreams/`"
  end

  def test_unit_context_is_empty_when_not_even_one_dream_fits
    assert_equal "", DreamBank.context(three_dreams, budget: 50)
  end

  def test_unit_the_header_says_a_dream_never_overrides_a_rule
    assert_includes DreamBank.context(three_dreams), "A dream never overrides a First Rule or an SOP."
  end

  # ── tags and the two sequences ─────────────────────────────────────────────

  def tagged(extra, question: "Do I merge on one read?")
    DREAM.sub("status: Approved", "status: approved\n#{extra}").sub("Do I merge on one read?", question)
  end

  def test_unit_parse_reads_tags_as_lists
    dream = DreamBank.parse(tagged("soul: [carl, xan]\nshape: ui+db\ntopic: review"), slug: "x")

    assert_equal %w[carl xan], dream.souls
    assert_equal({ "soul" => %w[carl xan], "shape" => %w[ui+db], "topic" => %w[review] }, dream.tags)
    refute dream.platform?
    assert DreamBank.parse(DREAM, slug: "y").platform?, "a dream with no soul tag is platform"
  end

  def test_unit_rejects_unknown_tag
    assert_nil DreamBank.parse(tagged("sole: carl"), slug: "x"), "an unknown front matter key"
    assert_nil DreamBank.parse(tagged("soul: nobody"), slug: "x"), "a soul that is not on the roster"
    assert_nil DreamBank.parse(tagged("topic: Two Words"), slug: "x"), "a tag value that is not one token"
    assert_equal [ "unknown front matter key `sole`" ], DreamBank.errors({ "sole" => "carl" })
    assert_equal [ "unknown soul `nobody`" ], DreamBank.errors({ "soul" => "nobody" })
    assert_empty DreamBank.errors({ "soul" => "turf-monster", "source" => "anything at all" })
  end

  def test_unit_reads_platform_and_soul_banks
    Dir.mktmpdir do |dir|
      write(dir, "platform/universal.md", DREAM)
      write(dir, "carl/review.md", tagged("soul: [carl, xan]", question: "Carl's question?"))
      write(dir, "carl/later.md", tagged("soul: carl", question: "Proposed?").sub("status: approved", "status: proposed"))
      write(dir, "turf-monster/contest.md", tagged("soul: turf-monster", question: "A contest question?"))
      write(dir, "INDEX.md", DREAM)
      write(dir, "platform/README.md", DREAM)

      assert_equal %w[later review universal contest], DreamBank.all(dir: dir).map(&:slug)
      assert_equal %w[carl carl platform turf-monster], DreamBank.all(dir: dir).map(&:home)
      assert_equal %w[universal], DreamBank.platform(dir: dir).map(&:slug)
      assert_equal %w[review], DreamBank.soul("carl", dir: dir).map(&:slug), "a proposed dream reaches no soul"
      assert_equal %w[review], DreamBank.soul("alex", dir: dir).map(&:slug), "alex is xan"
      assert_equal %w[contest], DreamBank.soul("turf_monster", dir: dir).map(&:slug)
      assert_empty DreamBank.soul("jasper", dir: dir)
    end
  end

  def test_unit_soul_context_names_the_seat_its_role_page_and_the_task
    dream = DreamBank.parse(tagged("soul: turf-monster"), slug: "contest")
    context = DreamBank.soul_context("turf_monster", [ dream ], task: "some-task")

    assert_includes context, "## Turf Monster's dream sequence · task some-task"
    assert_includes context, "`docs/agents/agents/turf_monster/role.md`"
    assert_includes context, "A dream never overrides a First Rule or an SOP."
    assert_includes context, "**Q: Do I merge on one read?** (`contest`)"
    assert_includes context, "Why: A late blocker"
    assert_equal "", DreamBank.soul_context("carl", [])
    assert_equal "", DreamBank.soul_context("nobody", [ dream ])
  end

  def test_unit_announce_prints_a_souls_sequence_and_never_raises
    Dir.mktmpdir do |dir|
      write(dir, "carl/review.md", tagged("soul: carl"))
      io = StringIO.new

      DreamBank.announce("carl", io: io, dir: dir)
      assert_includes io.string, "## Carl's dream sequence"

      [ "jasper", "nobody", "", nil ].each do |soul|
        quiet = StringIO.new
        DreamBank.announce(soul, io: quiet, dir: dir)
        assert_equal "", quiet.string, "#{soul.inspect} has nothing to print"
      end
      DreamBank.announce("carl", io: nil, dir: dir)
    end
  end

  def test_unit_platform_context_adds_the_helper_roster_inside_the_budget
    dreams = three_dreams
    plain = DreamBank.context(dreams)
    full = DreamBank.platform_context(dreams)

    assert full.start_with?(plain), "the dreams come first, whole"
    assert_includes full, "### Helper agents"
    assert_includes full, "`carl` Lead Architect"
    assert_includes full, "`bin/dream <soul>`"
    assert_equal plain, DreamBank.platform_context(dreams, budget: plain.size), "the roster never costs a dream"
    assert_operator DreamBank.platform_context(dreams, budget: full.size).size, :<=, full.size
    assert_equal "", DreamBank.platform_context([]), "no dreams, no block"
  end

  # ── the real bank ──────────────────────────────────────────────────────────

  def bank_files
    Dir.glob(File.join(DreamBank::DEFAULT_DIR, "**", "*.md")).reject { |p| DreamBank::SKIPPED.include?(File.basename(p)) }
  end

  def test_unit_every_tracked_dream_parses_with_a_known_status
    dreams = DreamBank.all

    assert_operator dreams.size, :>=, 20, "the bank lost dreams; DEFAULT_DIR may point at the wrong place"
    assert_equal bank_files.map { |p| File.basename(p, ".md") }.sort, dreams.map(&:slug).sort,
                 "a dream file failed to parse, so it would load nowhere and say nothing"
    assert_equal dreams.map(&:slug).uniq, dreams.map(&:slug), "two dreams share a slug"
    dreams.each do |dream|
      assert_includes %w[proposed approved], dream.status, "#{dream.slug} has an unknown status"
      refute_empty dream.why, "#{dream.slug} gives no reason; a dream without its why is a rule"
    end
  end

  def test_unit_every_dream_lives_in_the_directory_its_soul_tag_names
    DreamBank.all.each do |dream|
      assert_equal dream.sequence, dream.home, "#{dream.slug} is tagged for #{dream.sequence} and filed under #{dream.home}"
    end
  end

  def test_unit_the_real_bank_has_both_sequences
    assert_operator DreamBank.platform.size, :>=, 12
    assert_operator DreamBank.soul("carl").size, :>=, 3
    assert_equal DreamBank.approved.size, DreamBank.platform.size + DreamBank.approved.reject(&:platform?).size
  end

  def test_unit_index_matches_generator
    assert_equal DreamBank.index, File.read(File.join(DreamBank::DEFAULT_DIR, "INDEX.md")),
                 "docs/agents/dreams/INDEX.md is stale. Run `bin/dream index --write`."
  end

  def test_unit_index_lists_a_dream_under_every_sequence_it_loads_in
    Dir.mktmpdir do |dir|
      write(dir, "platform/universal.md", DREAM)
      write(dir, "carl/review.md", tagged("soul: [carl, xan]\ntopic: [review, merge]", question: "Carl | Xan?"))

      index = DreamBank.index(dir: dir)

      assert_includes index, "2 dreams."
      assert_includes index, "## Platform (1)"
      assert_includes index, "## Carl (1)\n\nLoads at: `bin/dream carl`"
      assert_includes index, "## Xan (1)"
      assert_equal 2, index.scan("| [`review`](carl/review.md) | Carl \\| Xan? | topic: review, merge | approved |").size
      refute_includes index, "## Jasper"
    end
  end

  private

  def write(dir, relative, text)
    path = File.join(dir, relative)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, text)
  end
end
