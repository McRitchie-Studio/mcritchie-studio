# frozen_string_literal: true

require "test_helper"
require_relative "../../support/books_fixtures"

# [unit] Books::Categorizer (first matching rule wins; a rule with no category
# asks for a person) and Books::Classify (who decided is recorded; a purpose
# can never smuggle a formula into the workbook).
class BooksClassifyTest < ActiveSupport::TestCase
  include BooksFixtures

  def categorize(description, cents) = Books::Categorizer.call(books_entity, description: description, amount_cents: cents)

  test "rules match the description with its spaces removed, first match wins" do
    assert_equal [ "interest_income", "rule:interest" ], categorize("INTEREST  PAYMENT", 100).to_h.values_at(:category, :classified_by)
    assert_equal "bank_fees", categorize("MONTHLY SERVICE FEE", -1000).category
  end

  test "a rule's sign limits it to money in or out" do
    assert_equal "member_distribution", categorize("US BANK NA PAYMENT 2383", -300_000).category
    assert_nil categorize("US BANK NA PAYMENT 2383", 300_000).category
  end

  test "a rule without a category, or no rule at all, leaves the line for a person" do
    wire = categorize("OUTGOINGFEDWIRETRANSFER - MANUAL", -100)
    assert_nil wire.category
    assert_match(/wire-needs-answer/, wire.note)
    assert_match(/no rule matched/, categorize("SOMETHING NEW", 100).note)
  end

  test "classify records the category, purpose, note and who decided" do
    entry = book_statement!(account: "savings", from: "2026-03-01", to: "2026-03-31", opening: 0,
                            lines: [ [ "2026-03-02", -500_00, "Transferdebit", nil, nil ] ]).entries.first
    Books::Classify.call(books_entity, ids: [ entry.id ], category: "member_distribution", purpose: "Owner draws",
                                       by: "alex-mcritchie", note: "personal", config: books_config)

    assert_equal %w[member_distribution Owner\ draws alex-mcritchie personal],
                 entry.reload.attributes.values_at("category", "purpose", "classified_by", "note")
    assert_in_delta Time.current, entry.classified_at, 5, "when the answer was given is recorded"

    Books::Classify.call(books_entity, ids: [ entry.id ], category: nil, by: "alex-mcritchie", config: books_config)
    assert_equal [ nil, nil, nil, nil ], entry.reload.attributes.values_at("category", "purpose", "classified_by", "classified_at")
  end

  test "classify refuses an unknown category, another entity's line, or a formula-shaped purpose" do
    entry = book_statement!(account: "savings", from: "2026-03-01", to: "2026-03-31", opening: 0,
                            lines: [ [ "2026-03-02", -500_00, "Transferdebit", nil, nil ] ]).entries.first
    call = ->(**kw) { Books::Classify.call(books_entity, ids: [ entry.id ], by: "x", config: books_config, **kw) }

    assert_raises(Books::Classify::Error) { call.(category: "not_a_category") }
    assert_raises(Books::Classify::Error) { call.(category: "member_distribution", purpose: "=HYPERLINK(1)") }
    assert_raises(Books::Classify::Error) { call.(category: "member_distribution", purpose: 'say "hi"') }
    [ "Owner*", "draws?", "~x", "<500", "a>b", "=x" ].each do |wild|
      assert_raises(Books::Classify::Error, wild) { call.(category: "member_distribution", purpose: wild) }
    end
    assert_raises(Books::Classify::Error) do
      Books::Classify.call(books_entity, ids: [ entry.id + 1000 ], category: "bank_fees", by: "x", config: books_config)
    end
    assert_nil entry.reload.category
  end

  test "classify refuses a purpose beside a category that is not a distribution, or beside an undo" do
    entry = book_statement!(account: "savings", from: "2026-03-01", to: "2026-03-31", opening: 0,
                            lines: [ [ "2026-03-02", -500_00, "Transferdebit", nil, nil ] ]).entries.first
    call = ->(**kw) { Books::Classify.call(books_entity, ids: [ entry.id ], by: "x", config: books_config, **kw) }

    error = assert_raises(Books::Classify::Error) { call.(category: "bank_fees", purpose: "Owner draws") }
    assert_match(/a purpose is for a distribution only/, error.message)
    assert_raises(Books::Classify::Error) { call.(category: nil, purpose: "Owner draws") }
    assert_equal [ nil, nil ], entry.reload.attributes.values_at("category", "purpose"), "nothing is stored"

    call.(category: "bank_fees", purpose: " ")
    assert_equal [ "bank_fees", nil ], entry.reload.attributes.values_at("category", "purpose"), "a blank purpose is no purpose"
  end
end
