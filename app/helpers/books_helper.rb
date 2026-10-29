# frozen_string_literal: true

# The /books review page's small readers (BooksController).
module BooksHelper
  # Bank text with any run of seven or more digits cut to its last four, so a
  # full account or card number can never reach the page. Statement dates
  # ("113026") and amounts stay as printed.
  def books_masked(text) = text.to_s.gsub(/\d{7,}/) { |run| "···#{run[-4..]}" }

  # "Money market ···9501": the account's label, last four digits only.
  def books_account(entity, key) = entity.account(key).label

  # The category picker's options, grouped by where each kind lands, each
  # carrying its kind so the purpose field shows only for a distribution.
  def books_category_options(config, selected = nil)
    groups = { "income" => "Income (P&L)", "expense" => "Expenses (P&L)", "asset" => "Assets (capitalized)",
               "contribution" => "Equity", "distribution" => "Equity", "transfer" => "Transfers" }
    grouped = config.categories.values.group_by { |c| groups.fetch(c.kind) }.map do |group, cats|
      [ group, cats.map { |c| [ c.label, c.key, { data: { kind: c.kind } } ] } ]
    end
    grouped_options_for_select(grouped, selected)
  end
end
