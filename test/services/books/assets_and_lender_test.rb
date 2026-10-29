# frozen_string_literal: true

require "test_helper"
require_relative "../../support/books_fixtures"
require_relative "../../support/books_formula_eval"

# [unit] Asset accounts and the lender package.
#
# A line first booked as an expense and then reclassified to an asset category
# (deal_costs) leaves the P&L, sits under assets, and the balance sheet and the
# equity rollforward still tie. The lender package is the close's own book with
# a Sources and Uses tab: its figures equal the close's, sources equal uses, and
# it is written beside the close in Drive. Every figure is the evaluated formula
# (BooksFormulaEval), held to the Ruby summary. Synthetic lines only.
class BooksAssetsAndLenderTest < ActiveSupport::TestCase
  include BooksFixtures

  setup do
    book_statement!(account: "savings", from: "2026-01-01", to: "2026-01-31", opening: 0, lines: [
      [ "2026-01-02", 400_000_00, "Transfer Credit", "member_contribution", nil ],
      [ "2026-01-31", 120_00, "INTEREST PAYMENT", "interest_income", nil ]
    ])
    book_statement!(account: "checking", from: "2026-02-01", to: "2026-02-28", opening: 0, lines: [
      [ "2026-02-05", 30_000_00, "Transfer Credit", "member_contribution", nil ],
      [ "2026-02-10", -3_000_00, "US BANK NA PAYMENT", "professional_fees", nil ],
      [ "2026-02-11", -15_000_00, "OUTGOINGFEDWIRETRANSFER", nil, nil ],
      [ "2026-02-12", -1_000_00, "OUTGOINGFEDWIRETRANSFER", "member_distribution", "Owner draws" ],
      [ "2026-02-13", -700_00, "RETAINER", "software_services", nil ],
      [ "2026-02-28", -18_000_00, "OUTGOINGFEDWIRETRANSFER", "professional_fees", nil ]
    ])
    @broker = BookEntry.find_by!(entity: "example", posted_on: Date.new(2026, 2, 10))
    @payback = BookEntry.find_by!(entity: "example", posted_on: Date.new(2026, 2, 28))
  end

  def build(month = "2026-02", layout: :close)
    entries = BookEntry.for_entity("example").through(Books.month_range(month).last).chronological.to_a
    statements = BookStatement.for_entity("example").order(:account_key, :period_start).to_a
    Books::Workbook.new(entity: books_entity(opened: "2026-01-01"), month: month, entries: entries, statements: statements,
                        checks: [], status: "draft", generated_at: Time.utc(2026, 3, 5, 15), generated_by: "test",
                        config: books_config, layout: layout)
  end

  def cell(eval, sheet, label, col = "B") = eval.value(sheet, "#{col}#{eval.row_of(sheet, label)}")

  def reclass!(*entries)
    Books::Classify.call(books_entity, ids: entries.map(&:id), category: "deal_costs", by: "mack",
                                       note: "Alex McRitchie 2026-10-28: broker payments, capitalize", config: books_config)
  end

  def assert_ties(eval)
    assert_in_delta 0, cell(eval, "Balance Sheet", "Check: assets − liabilities − equity (must be 0)"), 0.001
  end

  test "deal_costs is an asset category in the real chart of accounts" do
    assert_equal "asset", Books::Config.current.category("deal_costs").kind
    assert_equal [ "deal_costs" ], Books::Config.current.categories_of("asset").map(&:key)
  end

  test "reclassing a professional fee to deal_costs moves it off the P&L onto assets, and every check still ties" do
    before = build
    before_eval = BooksFormulaEval.new(before.package)
    assert_in_delta 21_000.00, cell(before_eval, "P&L", "Professional fees", "C"), 0.001
    assert_in_delta 0, cell(before_eval, "Balance Sheet", "Deal costs (capitalized)"), 0.001
    assert_ties(before_eval)

    reclass!(@broker, @payback)
    assert_equal %w[deal_costs deal_costs], [ @broker.reload.category, @payback.reload.category ]
    assert_equal "mack", @broker.classified_by
    assert @broker.classified_at

    book = build
    eval = BooksFormulaEval.new(book.package)
    summary = book.summary

    assert_in_delta 0, cell(eval, "P&L", "Professional fees", "C"), 0.001
    assert_in_delta summary["net_income_ytd_cents"] / 100.0, cell(eval, "P&L", "Net income", "D"), 0.001
    assert_in_delta 120.00 - 700.00, summary["net_income_ytd_cents"] / 100.0, 0.001
    assert_in_delta 21_000.00, cell(eval, "Balance Sheet", "Deal costs (capitalized)"), 0.001
    assert_equal 21_000_00, summary["capitalized_cents"]
    assert_in_delta summary["total_assets_cents"] / 100.0, cell(eval, "Balance Sheet", "Total assets"), 0.001
    assert_in_delta summary["equity_cents"] / 100.0, cell(eval, "Balance Sheet", "Total equity"), 0.001
    assert_equal summary["cash_cents"] + 21_000_00, summary["total_assets_cents"]
    assert_ties(eval)
    assert_in_delta 0, cell(eval, "Equity", "Check: rollforward − balance sheet (must be 0)"), 0.001
    # Total equity did not move: a reclass between an expense and an asset only
    # moves the cost between retained earnings and the asset line.
    assert_in_delta cell(before_eval, "Balance Sheet", "Total assets") + 21_000.00, cell(eval, "Balance Sheet", "Total assets"), 0.001
  end

  test "an asset line from an earlier year stays out of the year-start equity, so the rollforward ties" do
    book_statement!(account: "savings", from: "2025-12-01", to: "2025-12-31", opening: 0, lines: [
      [ "2025-12-15", 50_000_00, "Transfer Credit", "member_contribution", nil ],
      [ "2025-12-20", -5_000_00, "OUTGOINGFEDWIRETRANSFER", "deal_costs", nil ]
    ])
    eval = BooksFormulaEval.new(build.package)

    assert_in_delta 50_000.00, cell(eval, "Equity", "Equity at the start of the year"), 0.001 # the deal cost is an asset, not a loss
    assert_in_delta 0, cell(eval, "Equity", "Check: rollforward − balance sheet (must be 0)"), 0.001
    assert_ties(eval)
  end

  test "the lender package's sources equal its uses, and each row is the ledger's" do
    reclass!(@broker, @payback)
    book = build(layout: :lender)
    eval = BooksFormulaEval.new(book.package)
    names = book.package.workbook.worksheets.map { |w| CGI.unescapeHTML(w.name) }
    summary = book.summary

    assert_equal [ "Notes", "P&L", "Balance Sheet", "Sources and Uses", "Ledger" ], names
    assert_in_delta 430_000.00, cell(eval, "Sources and Uses", "Member contributions"), 0.001
    assert_in_delta 120.00, cell(eval, "Sources and Uses", "Income"), 0.001
    assert_in_delta summary["sources_cents"] / 100.0, cell(eval, "Sources and Uses", "Total sources"), 0.001
    assert_in_delta 700.00, cell(eval, "Sources and Uses", "Expenses"), 0.001
    assert_in_delta 1_000.00, cell(eval, "Sources and Uses", "Member distributions: Owner draws"), 0.001
    assert_in_delta 21_000.00, cell(eval, "Sources and Uses", "Deal costs (capitalized)"), 0.001
    assert_in_delta 15_000.00, cell(eval, "Sources and Uses", "Unclassified lines (to confirm), net"), 0.001
    cash = cell(eval, "Sources and Uses", "Cash on hand: Savings ···1234") + cell(eval, "Sources and Uses", "Cash on hand: Checking ···5678")
    assert_in_delta summary["cash_cents"] / 100.0, cash, 0.001
    assert_in_delta 0, cell(eval, "Sources and Uses", "Check: sources − uses (must be 0)"), 0.001
    assert_in_delta cell(eval, "Sources and Uses", "Total sources"), cell(eval, "Sources and Uses", "Total uses"), 0.001
  end

  test "the lender package's P&L and balance sheet figures equal the close's, cell for cell" do
    reclass!(@broker)
    close = BooksFormulaEval.new(build.package)
    lender = BooksFormulaEval.new(build(layout: :lender).package)

    [ [ "P&L", "Net income", "D" ], [ "P&L", "Total expenses", "D" ], [ "Balance Sheet", "Total assets", "B" ],
      [ "Balance Sheet", "Total equity", "B" ], [ "Balance Sheet", "Deal costs (capitalized)", "B" ],
      [ "Balance Sheet", "Unclassified lines (to confirm)", "B" ] ].each do |sheet, label, col|
      assert_in_delta cell(close, sheet, label, col), cell(lender, sheet, label, col), 0.001, "#{sheet} #{label}"
    end
    assert_ties(lender)
  end

  test "an unknown layout is refused" do
    assert_raises(ArgumentError) { build(layout: :bogus) }
  end
end
