# frozen_string_literal: true

# The /books review page's small readers (BooksController).
module BooksHelper
  # Bank text with any run of seven or more digits cut to its last four, so a
  # full account or card number can never reach the page. A run may be broken
  # by single spaces or dashes ("1234 5678 9012", "1234-5678-9012"): those
  # count as one number. Statement dates ("113026"), a real ISO date
  # ("2026-10-28", as a cited note carries) and amounts ("$1,234.56") stay as
  # printed.
  BOOKS_ISO_DATE = /\b(?:19|20)\d{2}-(?:0[1-9]|1[0-2])-(?:0[1-9]|[12]\d|3[01])\b(?!-\d)/
  BOOKS_DIGIT_RUN = /\d(?:[ -]?\d){6,}/
  def books_masked(text)
    text.to_s.gsub(/(#{BOOKS_ISO_DATE})|#{BOOKS_DIGIT_RUN}/) do |run|
      next run if Regexp.last_match(1)

      "···#{run.delete("^0-9")[-4..]}"
    end
  end

  # "Money market ···9501": the account's label, last four digits only.
  def books_account(entity, key) = entity.account(key).label

  # The category picker's options, grouped by where each kind lands, each
  # carrying its kind (data-kind), the ledger kind it books to.
  def books_category_options(config, selected = nil)
    groups = { "income" => "Income (P&L)", "expense" => "Expenses (P&L)", "asset" => "Assets (capitalized)",
               "contribution" => "Equity", "distribution" => "Equity", "transfer" => "Transfers" }
    grouped = config.categories.values.group_by { |c| groups.fetch(c.kind) }.map do |group, cats|
      [ group, cats.map { |c| [ c.label, c.key, { data: { kind: c.kind } } ] } ]
    end
    grouped_options_for_select(grouped, selected)
  end
end
