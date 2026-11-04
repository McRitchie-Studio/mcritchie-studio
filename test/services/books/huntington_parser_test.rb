# frozen_string_literal: true

require "test_helper"
require_relative "../../support/books_fixtures"

# [unit] Books::HuntingtonParser on synthesized statement text, laid out the way
# pdf-reader prints a 2026 Huntington business statement. No real statement is
# in the repo: the fixture text (test/support/books_fixtures.rb) is made up.
class BooksHuntingtonParserTest < ActiveSupport::TestCase
  STATEMENT = BooksFixtures::HUNTINGTON_STATEMENT

  test "reads the summary, the account and the period" do
    parsed = Books::HuntingtonParser.parse(STATEMENT)

    assert_equal "Huntington Business Premier Plus MMA", parsed.product
    assert_equal "1234", parsed.last4
    assert_equal [ Date.new(2026, 12, 1), Date.new(2026, 12, 31) ], [ parsed.period_start, parsed.period_end ]
    assert_equal [ 1_000_000, 125_040, 300_000, 6_000, 819_040 ],
                 [ parsed.opening_cents, parsed.credits_cents, parsed.debits_cents, parsed.service_charges_cents, parsed.closing_cents ]
  end

  test "signs credits in, debits and charges out, nets a waived charge, and joins continuation lines" do
    lines = Books::HuntingtonParser.parse(STATEMENT).lines

    assert_equal [ 120_000, 5_040, -100_000, -200_000, -5_000, -1_000 ], lines.map(&:amount_cents)
    assert_equal %w[credit credit debit debit service_charge service_charge], lines.map(&:section)
    assert_equal "US BANK NA PAYMENT 261203 BILL PAYACCT XXXXXXX2383 PAYEE000001 CONTINUED TEXT", lines[3].description
  end

  # The row shape is the one a real October 2026 statement printed: the same
  # columns, a charge of 100, a charge of 20, and a row with only the waiver.
  WAIVER_ONLY = <<~TXT
    THE HUNTINGTON NATIONAL BANK
    Huntington Business Checking 100                                       Account: -------5678
    Statement Activity From:                   Beginning Balance                       $1,000.00
    10/01/26 to 10/31/26                       Total Service Charges (-)                  100.00
                                               Ending Balance                            $900.00
    Service Charge Detail                                                                 Account:-------5678
    Date      Service Charge (-)     Waives and    Discounts (+)      Description
    10/16               100.00                                        OTHER SERVICE FEES
    10/16                20.00                                        MONTHLY SERVICE FEE
    10/16                                              20.00          PROMOTIONAL WAIVE - MONTHLY SERVICE FEE
  TXT

  test "a row with only a waiver nets against the charges, so the statement reconciles" do
    parsed = Books::HuntingtonParser.parse(WAIVER_ONLY)

    assert_equal [ -10_000, -2_000, 2_000 ], parsed.lines.map(&:amount_cents)
    assert_equal %w[service_charge service_charge service_charge], parsed.lines.map(&:section)
    assert_empty parsed.problems
  end

  test "a waiver-only row on a Continued page with no column header uses the column from the page before" do
    text = WAIVER_ONLY.sub(/^10\/16 +20\.00 +PROMOTIONAL/) do |row|
      "\f\nService Charge Detail (Continued)                                                     Account:-------5678\n#{row}"
    end
    parsed = Books::HuntingtonParser.parse(text)

    assert_equal [ -10_000, -2_000, 2_000 ], parsed.lines.map(&:amount_cents)
    assert_empty parsed.problems
  end

  test "a row with a charge and a waiver on one line still nets as before" do
    text = WAIVER_ONLY.sub(/^10\/16 +20\.00 +MONTHLY.*\n^10\/16 +20\.00.*\n/,
                           "10/16                20.00             20.00                      MONTHLY SERVICE FEE\n")
    parsed = Books::HuntingtonParser.parse(text)

    assert_equal [ -10_000, 0 ], parsed.lines.map(&:amount_cents)
    assert_empty parsed.problems
  end

  test "a one-amount row with no column header reads as a charge, and the statement is refused" do
    problems = Books::HuntingtonParser.parse(WAIVER_ONLY.sub(/^Date .*Waives and.*\n/, "")).problems

    assert_includes problems, "charge lines total $140.00, the summary says $100.00"
  end

  test "a line dated after the period's month belongs to the year before" do
    lines = Books::HuntingtonParser.parse(STATEMENT.sub("12/01/26 to 12/31/26", "01/01/27 to 01/31/27")).lines

    assert_equal Date.new(2026, 11, 30), lines[2].posted_on
    assert_equal Date.new(2026, 12, 15), lines[0].posted_on
  end

  test "a statement whose lines match the bank's totals has no problems" do
    assert_empty Books::HuntingtonParser.parse(STATEMENT).problems
  end

  test "a line the parser cannot see shows up as a problem, never as a quiet gap" do
    missing = STATEMENT.sub("12/31                50.40     INTEREST PAYMENT\n", "12/31     INTEREST PAYMENT (amount on next page)\n")
    problems = Books::HuntingtonParser.parse(missing).problems

    assert_includes problems, "credit lines total $1,200.00, the summary says $1,250.40"
  end

  test "a page break ends a section, so the next page's text is not read as lines" do
    text = STATEMENT.sub("Service Charge Summary", "\f\nSome legal notice 12/31 9.99 not a line\nService Charge Summary")

    assert_equal 6, Books::HuntingtonParser.parse(text).lines.size
  end

  test "text with no period or no account is refused" do
    assert_raises(Books::HuntingtonParser::Error) { Books::HuntingtonParser.parse("hello") }
    assert_raises(Books::HuntingtonParser::Error) { Books::HuntingtonParser.parse(STATEMENT.gsub(/Account: ?-+1234/, "")) }
  end
end
