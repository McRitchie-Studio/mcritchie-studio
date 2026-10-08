# frozen_string_literal: true

# Tests for bin/lib/dream_selector.rb, over the fixture bank in test/fixtures/dreams/.
#   ruby -Itest test/lib/dream_selector_test.rb
#
#   [unit] scoring, ranking, the tie-break and the selection; each with its control.

require "minitest/autorun"
require "stringio"
require "tmpdir"
require "fileutils"
require_relative "../../bin/lib/dream_bank"
require_relative "../../bin/lib/dream_selector"

class DreamSelectorTest < Minitest::Test
  BANK = File.expand_path("../fixtures/dreams", __dir__)

  def facts(stage: "building", title: "Settle Payout Once", acceptance: [ "A retried payout pays one settlement" ],
            repositories: [ "turf-monster" ], risk_tags: [ "money" ], shape: "backend")
    { "stage" => stage, "title" => title,
      "metadata" => { "devops" => { "repositories" => repositories, "risk_tags" => risk_tags, "shape" => shape,
                                    "acceptance" => acceptance } } }
  end

  def payment_task(**overrides)
    DreamSelector.task(facts(**overrides))
  end

  def bank
    @bank ||= DreamBank.all(dir: BANK)
  end

  def dream(slug)
    bank.find { |candidate| candidate.slug == slug } || flunk("no fixture dream #{slug}")
  end

  def score(slug, task = payment_task)
    DreamSelector.score(task, dream(slug))
  end

  def test_unit_ranks_by_repo_shape_risk_stage_topic
    assert_equal 10, score("settle-once-per-entry"), "repo 3 + risk 3 + shape 2 + two topic words"
    assert_equal 3, score("money-moves-in-a-transaction"), "risk alone"
    assert_equal 3, score("read-the-contest-state-first"), "repo alone"
    assert_equal 0, score("untagged-habit")
    assert_equal 0, score("docs-guard-names-its-rule"), "control: a docs-guard dream shares nothing with a payment task"
    assert_equal 5, score("money-moves-in-a-transaction", payment_task(title: "Ledger Balance Check")),
                 "risk 3 + two topic words; the plural `balances` matches `balance`"

    review = payment_task(stage: "submitted", title: "Payment Review", acceptance: [])
    assert_equal 8, score("money-review-reads-the-ledger", review), "repo 3 + risk 3 + stage 1 + topic 1"
    assert_equal 7, score("money-review-reads-the-ledger", payment_task(title: "Payment", acceptance: [])),
                 "control: the same dream loses the stage point on a building task"

    ranked = DreamSelector.rank(payment_task, DreamBank.soul("pokemon", dir: BANK)).map(&:slug)
    assert_equal "settle-once-per-entry", ranked.first
    assert_operator ranked.index("money-moves-in-a-transaction"), :<, ranked.index("docs-guard-names-its-rule")
  end

  def test_unit_topic_overlap_is_capped_and_ignores_stop_words
    wordy = DreamBank.parse("---\nquestion: \"Q?\"\nanswer: \"A.\"\nstatus: approved\n" \
                            "topic: [payout, settlement, retry, ledger, the]\n---\n", slug: "wordy")
    task = DreamSelector.task(facts(title: "The Payout Settlement Retry Ledger", acceptance: [], repositories: [],
                                    risk_tags: [], shape: nil))

    assert_equal 3, DreamSelector.score(task, wordy), "four topic words match; the cap is three"
    assert_equal %w[payout settlement retry ledger], task.words, "`the` is a stop word"
  end

  def test_unit_an_unknown_tag_value_or_missing_facts_scores_zero
    odd = DreamBank.parse("---\nquestion: \"Q?\"\nanswer: \"A.\"\nstatus: approved\n" \
                          "repo: never-seen\nshape: never-seen\nrisk: never-seen\nstage: never-seen\n---\n", slug: "odd")

    assert_equal 0, DreamSelector.score(payment_task, odd)
    [ nil, {}, { "metadata" => "text" }, { "metadata" => { "devops" => [] } } ].each do |broken|
      assert_equal 0, DreamSelector.score(DreamSelector.task(broken), dream("settle-once-per-entry")), broken.inspect
    end
  end

  def test_unit_tie_break_is_slug_order
    tied = DreamSelector.rank(payment_task, [ dream("read-the-contest-state-first"), dream("money-moves-in-a-transaction") ])

    assert_equal %w[money-moves-in-a-transaction read-the-contest-state-first], tied.map(&:slug)
    assert_equal tied.map(&:slug), DreamSelector.rank(payment_task, tied.reverse).map(&:slug), "input order does not decide"

    docs = payment_task(repositories: [ "mcritchie-studio" ], risk_tags: [ "none" ], shape: "docs", title: "Docs Guard")
    assert_equal "docs-guard-names-its-rule", DreamSelector.rank(docs, DreamBank.soul("pokemon", dir: BANK)).first.slug,
                 "control: the score outranks the slug order"
  end

  def test_unit_platform_universals_always_included
    selection = DreamSelector.select(payment_task, bank, soul: "pokemon", limit: 2)

    assert_equal %w[settle-once-per-entry entry-fee-charges-once], selection.picked.map(&:slug)
    assert_equal %w[list-the-candidates report-what-you-verified], selection.universals.map(&:slug),
                 "the universals score 0 here and load all the same"
    assert_includes selection.hidden.map(&:slug), "docs-guard-names-its-rule"
    assert_includes selection.hidden.map(&:slug), "wait-for-the-light", "another soul's dream is not shown"
    refute_includes (selection.shown + selection.hidden).map(&:slug), "proposed-money-idea", "control: a proposed dream is nowhere"
    assert_equal bank.count(&:approved?), (selection.shown + selection.hidden).size

    nobody = DreamSelector.select(payment_task, bank, soul: "mack")
    assert_empty nobody.picked
    assert_equal 2, nobody.universals.size
  end

  def test_unit_the_limit_is_twelve_and_a_shorter_sequence_is_shown_whole
    selection = DreamSelector.select(payment_task, bank, soul: "pokemon")

    assert_equal 12, DreamSelector::LIMIT
    assert_equal 14, DreamBank.soul("pokemon", dir: BANK).size
    assert_equal 12, selection.picked.size
    assert_equal %w[docs-guard-names-its-rule untagged-habit], (selection.hidden.map(&:slug) & pokemon_slugs).sort,
                 "the two that score 0 rank out"

    carl = DreamSelector.select(payment_task, bank, soul: "carl")
    assert_equal %w[money-review-reads-the-ledger wait-for-the-light], carl.picked.map(&:slug),
                 "control: a sequence under the limit keeps its zero-score dream"
  end

  def pokemon_slugs
    DreamBank.soul("pokemon", dir: BANK).map(&:slug)
  end

  def context(soul = "pokemon", **options)
    DreamBank.task_context(soul, bank, facts: facts, task: "settle-payout-once", **options)
  end

  def test_unit_why_lines_drop_before_dreams
    full = context(budget: nil)
    assert_equal 14, full.scan("\nWhy: ").size, "twelve picked and two universals, each with its Why; 4 of 18 are not shown"
    assert_operator full.index("settle-once-per-entry"), :<, full.index("entry-fee-charges-once"), "rank order"
    assert_operator full.index("retried-webhook-is-deduplicated"), :<, full.index("### Platform dreams")
    assert full.end_with?("\n\n4 not shown: bin/dream list --task settle-payout-once"), full[-80..]

    mixed = context(budget: full.size - 1)
    assert_equal 12, mixed.scan("\nWhy: ").size, "the platform Why lines drop first"
    assert_includes mixed, "Why: A retry after a timeout pays the same entry again."
    refute_includes mixed, "Why: An accepted request is not a delivered one."

    one = context(budget: mixed.size - 1)
    assert_equal 12, one.scan("\nWhy: ").size, "a platform dream drops before a selected Why"
    assert_includes one, "list-the-candidates"
    refute_includes one, "report-what-you-verified", "the last platform dream drops first"
    assert one.end_with?("5 not shown: bin/dream list --task settle-payout-once"), one[-80..]

    none = context(budget: one.size - 1)
    assert_equal 12, none.scan("\nWhy: ").size
    refute_includes none, "### Platform dreams"
    assert none.end_with?("6 not shown: bin/dream list --task settle-payout-once"), none[-80..]

    brief = context(budget: none.size - 1)
    refute_includes brief, "\nWhy: "
    assert_equal 12, brief.scan("**Q: ").size, "every selected dream survives the loss of the Why lines"

    tight = context(budget: brief.size - 1)
    assert_operator tight.size, :<=, brief.size - 1
    refute_includes tight, "retried-webhook-is-deduplicated", "the lowest-ranked pick drops last of all"
    assert_equal 11, tight.scan("**Q: ").size
    assert tight.end_with?("7 not shown: bin/dream list --task settle-payout-once"), tight[-80..]

    assert_operator context.size, :<=, DreamBank::CALL_BUDGET
    assert_equal 6_000, DreamBank::CALL_BUDGET
    assert_equal "", context(budget: 10), "nothing prints when not even the heading fits"
  end

  def test_unit_twenty_platform_dreams_cost_no_selected_dream_or_why
    extra = (1..18).map do |n|
      DreamBank::Dream.new(slug: "platform-extra-#{n}", question: "Platform question number #{n}, long enough to cost room?",
                           answer: "A platform answer of ordinary length, number #{n}. #{"It runs on. " * 8}".strip, why: "A platform reason.",
                           status: "approved", tags: {}, home: "platform")
    end
    wide = bank + extra
    selection = DreamSelector.select(payment_task, wide, soul: "pokemon")
    assert_equal [ 12, 20 ], [ selection.picked.size, selection.universals.size ]
    everything = DreamBank.task_context("pokemon", wide, facts: facts, task: "settle-payout-once", budget: nil)
    assert_operator everything.size, :>, DreamBank::CALL_BUDGET, "control: the whole block is over the budget"

    text = DreamBank.task_context("pokemon", wide, facts: facts, task: "settle-payout-once")

    assert_operator text.size, :<=, DreamBank::CALL_BUDGET
    selection.picked.each { |dream| assert_includes text, "(`#{dream.slug}`)\nA: #{dream.answer}\nWhy: #{dream.why}" }
    shown = text.scan("**Q: ").size
    assert_operator shown, :<, 32
    assert text.end_with?("#{wide.count(&:approved?) - shown} not shown: bin/dream list --task settle-payout-once"), text[-80..]
  end

  def test_unit_a_soul_without_dreams_or_off_the_roster_gets_no_block
    assert_equal "", context("mack")
    assert_equal "", context("nobody")
    refute_equal "", context("carl"), "control"
  end

  def test_unit_announce_selects_with_facts_and_prints_the_whole_sequence_without
    selected = StringIO.new
    DreamBank.announce("pokemon", io: selected, task: "settle-payout-once", facts: facts, dir: BANK)
    assert_equal context + "\n", selected.string
    refute_includes selected.string, "docs-guard-names-its-rule"

    [ nil, {}, "not json" ].each do |unread|
      whole = StringIO.new
      DreamBank.announce("pokemon", io: whole, task: "settle-payout-once", facts: unread, dir: BANK)
      assert_equal DreamBank.soul_context("pokemon", bank, task: "settle-payout-once") + "\n", whole.string, unread.inspect
      assert_includes whole.string, "docs-guard-names-its-rule"
    end
  end

  def test_unit_one_unreadable_or_malformed_file_leaves_the_others_loaded
    Dir.mktmpdir do |dir|
      FileUtils.cp_r(File.join(BANK, "."), dir)
      assert_equal bank.map(&:slug), DreamBank.all(dir: dir).map(&:slug), "control: every file readable loads them all"

      FileUtils.mkdir_p(File.join(dir, "pokemon", "a-directory-not-a-file.md"))
      File.write(File.join(dir, "pokemon", "malformed.md"), "---\nquestion: [unclosed\n---\n")
      File.binwrite(File.join(dir, "platform", "not-utf8.md"), "---\nquestion: \"\xFF\xFE?\"\nanswer: \"A.\"\n---\n")

      assert_equal bank.map(&:slug), DreamBank.all(dir: dir).map(&:slug)
      assert_equal 14, DreamBank.soul("pokemon", dir: dir).size
    end
  end

  def test_unit_announce_survives_a_missing_bank_and_unusable_facts
    io = StringIO.new
    assert_nil DreamBank.announce("pokemon", io: io, task: "t", facts: facts, dir: "/nonexistent/dreams")
    assert_equal "", io.string

    DreamBank.announce("pokemon", io: io, task: "t", facts: { "metadata" => 7, "title" => [ 1 ], "stage" => {} }, dir: BANK)
    assert_includes io.string, "## Pokémon's dream sequence · task t", "unusable facts rank in slug order; nothing raises"
  end
end
