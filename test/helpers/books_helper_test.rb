# frozen_string_literal: true

require "test_helper"

# [unit] BooksHelper#books_masked: only an account number's last four digits
# may reach /books, however the bank prints it. Every number here is synthetic.
class BooksHelperTest < ActionView::TestCase
  include BooksHelper

  test "[unit] an unbroken run of seven or more digits shows its last four only" do
    assert_equal "ACCT ···9012", books_masked("ACCT 123456789012")
    assert_equal "REF ···4567", books_masked("REF 1234567")
  end

  test "[unit] a number broken by spaces or dashes counts as one number and shows its last four only" do
    assert_equal "ACCT ···9012", books_masked("ACCT 1234-5678-9012")
    assert_equal "CARD ···0004", books_masked("CARD 4000 0000 0000 0004")
    assert_equal "BNF ···7890 PAID", books_masked("BNF 1234-56-7890 PAID")
    assert_equal "TO ···8899 AND ···4455", books_masked("TO 11 22 33 44 55 66 77 88 99 AND 1122-3344-55")
  end

  test "[unit] dates, short references and amounts stay as printed" do
    assert_equal "Alex McRitchie 2026-10-28: a draw", books_masked("Alex McRitchie 2026-10-28: a draw")
    assert_equal "STMT 113026 $1,234.56", books_masked("STMT 113026 $1,234.56")
    assert_equal "on 2026-10-28 2 wires", books_masked("on 2026-10-28 2 wires")
    assert_equal "REF 12 34 5", books_masked("REF 12 34 5")
    assert_equal "", books_masked(nil)
  end

  test "[unit] a date-shaped run that is not a real date, or runs on, is still masked" do
    assert_equal "···3344", books_masked("1234-22-3344")
    assert_equal "···1234", books_masked("2026-10-28-1234")
  end
end
