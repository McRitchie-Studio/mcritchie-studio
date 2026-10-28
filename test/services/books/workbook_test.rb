# frozen_string_literal: true

require "test_helper"
require_relative "../../support/books_fixtures"
require_relative "../../support/books_formula_eval"

# [unit] Books::Workbook: the Sheet's formulas, evaluated, give the figures the
# Ruby summary computes from the same lines. The P&L's net income ties to the
# equity rollforward, the rollforward ties to the balance sheet, the balance
# sheet balances, and equity lines never reach the P&L.
class BooksWorkbookTest < ActiveSupport::TestCase
  include BooksFixtures

  setup do
    # Last year: one contribution and some interest, so the year-start equity is not zero.
    book_statement!(account: "savings", from: "2025-12-01", to: "2025-12-31", opening: 0, lines: [
      [ "2025-12-10", 100_000_00, "INCOMING FEDWIRETRANSFER", "member_contribution", nil ],
      [ "2025-12-31", 12_50, "INTEREST PAYMENT", "interest_income", nil ]
    ])
    book_statement!(account: "savings", from: "2026-01-01", to: "2026-01-31", opening: 100_012_50, lines: [
      [ "2026-01-31", 410_25, "INTEREST PAYMENT", "interest_income", nil ],
      [ "2026-01-16", -10_00, "MONTHLY SERVICEFEE", "bank_fees", nil ]
    ])
    book_statement!(account: "savings", from: "2026-02-01", to: "2026-02-28", opening: 100_412_75, lines: [
      [ "2026-02-03", -20_000_00, "INTERNETTFRTO CHECKING XXXXXXX5678", "internal_transfer", nil ],
      [ "2026-02-27", 350_00, "INTEREST PAYMENT", "interest_income", nil ],
      [ "2026-02-20", -40_000_00, "Transferdebit", nil, nil ]
    ])
    book_statement!(account: "checking", from: "2026-02-01", to: "2026-02-28", opening: 0, lines: [
      [ "2026-02-03", 20_000_00, "INTERNETTFRFRM CHECKING XXXXXXX1234", "internal_transfer", nil ],
      [ "2026-02-10", -3_000_00, "US BANK NA PAYMENT", "member_distribution", "Acquisition costs" ],
      [ "2026-02-12", -1_500_00, "OUTGOINGFEDWIRETRANSFER", "member_distribution", "Owner draws" ],
      [ "2026-02-13", -75_00, "WIRE TRANSFER FEES(OUTGOING)", "bank_fees", nil ],
      [ "2026-02-14", 2_500_00, "CLIENT PAYMENT", "revenue", nil ]
    ])
  end

  def build(month = "2026-02", status: "draft")
    entries = BookEntry.for_entity("example").through(Books.month_range(month).last).chronological.to_a
    statements = BookStatement.for_entity("example").order(:account_key, :period_start).to_a
    Books::Workbook.new(entity: books_entity, month: month, entries: entries, statements: statements, checks: [],
                        status: status, generated_at: Time.utc(2026, 3, 5, 15), generated_by: "test", config: books_config)
  end

  def cell(eval, sheet, label, col = "B") = eval.value(sheet, "#{col}#{eval.row_of(sheet, label)}")

  test "the P&L counts income and expenses only, by month, and its year to date matches the summary" do
    book = build
    eval = BooksFormulaEval.new(book.package)
    summary = book.summary

    assert_in_delta 760.25, cell(eval, "P&L", "Interest income", "D"), 0.001 # Jan + Feb interest; Dec is last year
    assert_in_delta 2_500.00, cell(eval, "P&L", "Revenue", "D"), 0.001
    assert_in_delta 85.00, cell(eval, "P&L", "Bank fees", "D"), 0.001
    assert_in_delta summary["income_ytd_cents"] / 100.0, cell(eval, "P&L", "Total income", "D"), 0.001
    assert_in_delta summary["expenses_ytd_cents"] / 100.0, cell(eval, "P&L", "Total expenses", "D"), 0.001
    assert_in_delta summary["net_income_ytd_cents"] / 100.0, cell(eval, "P&L", "Net income", "D"), 0.001
    assert_in_delta 400.25, cell(eval, "P&L", "Net income", "B"), 0.001 # January alone
  end

  test "the balance sheet balances, its cash matches the statements, and draws sit in equity by purpose" do
    book = build
    eval = BooksFormulaEval.new(book.package)

    assert_in_delta 0, cell(eval, "Balance Sheet", "Check: assets − liabilities − equity (must be 0)"), 0.001
    assert_in_delta 0, cell(eval, "Balance Sheet", "Cash: Savings ···1234", "D"), 0.001
    assert_in_delta 0, cell(eval, "Balance Sheet", "Cash: Checking ···5678", "D"), 0.001
    assert_in_delta book.summary["cash_cents"] / 100.0, cell(eval, "Balance Sheet", "Total assets"), 0.001
    assert_in_delta(-3_000.00, cell(eval, "Balance Sheet", "Member distributions: Acquisition costs"), 0.001)
    assert_in_delta(-1_500.00, cell(eval, "Balance Sheet", "Member distributions: Owner draws"), 0.001)
    assert_in_delta(-40_000.00, cell(eval, "Balance Sheet", "Unclassified lines (to confirm)"), 0.001)
    assert_in_delta 100_000.00, cell(eval, "Balance Sheet", "Member contributions"), 0.001
  end

  test "the equity rollforward starts from last year's close and ties to the balance sheet" do
    eval = BooksFormulaEval.new(build.package)

    assert_in_delta 100_012.50, cell(eval, "Equity", "Equity at the start of the year"), 0.001
    assert_in_delta 0, cell(eval, "Equity", "Check: rollforward − balance sheet (must be 0)"), 0.001
    assert_in_delta 0, cell(eval, "Equity", "Member contributions"), 0.001 # this year's only
  end

  test "an earlier month's close leaves later lines out" do
    book = build("2026-01")
    eval = BooksFormulaEval.new(book.package)

    assert_in_delta 400.25, cell(eval, "P&L", "Net income", "B"), 0.001
    assert_in_delta 100_412.75, cell(eval, "Balance Sheet", "Total assets"), 0.001
    assert_in_delta 0, cell(eval, "Balance Sheet", "Check: assets − liabilities − equity (must be 0)"), 0.001
    assert_equal 0, book.summary["unclassified"]
  end

  test "bank text stays text: a description that looks like a formula is escaped on the Ledger" do
    BookStatement.last.entries.create!(entity: "example", account_key: "checking", position: 99, posted_on: Date.new(2026, 2, 15),
                                       amount_cents: 0, section: "credit", description: "=HYPERLINK(\"http://x\")")
    cell = build.package.workbook.worksheets.find { |ws| ws.name == "Ledger" }.rows.to_a.find { |r| r.cells[2].value.to_s.include?("HYPERLINK") }.cells[2]

    assert cell.escape_formulas, "a Ledger description must never be written as a formula"
  end

  test "the xlsx serializes" do
    bytes = build.to_xlsx

    assert bytes.start_with?("PK"), "an xlsx is a zip"
  end
end
