# frozen_string_literal: true

# Tests for bin/lib/dream_selector.rb, over the fixture bank in test/fixtures/dreams/.
#   ruby -Itest test/lib/dream_selector_test.rb
#
#   [unit] scoring, ranking, the tie-break and the selection; each with its control.

require "minitest/autorun"
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

    assert_equal %w[settle-once-per-entry money-moves-in-a-transaction], selection.picked.map(&:slug)
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

  def test_unit_a_soul_with_fewer_dreams_than_the_limit_is_shown_them_all
    selection = DreamSelector.select(payment_task, bank, soul: "pokemon")

    assert_equal 12, DreamSelector::LIMIT
    assert_equal 5, selection.picked.size
    assert_equal "untagged-habit", selection.picked.last.slug, "zero scores rank last, in slug order"
  end
end
