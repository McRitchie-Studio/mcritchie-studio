# frozen_string_literal: true

# The month-close bookkeeping (task studio-books-month-close). Statements go in
# through Books::Intake, the ledger lives in book_entries, and Books::Close
# writes each month's Sheet and PDF to the entity's Drive.
# SOP: docs/agents/agents/mack/sops/close-the-month.md. Operator CLI: bin/books.
module Books
  module_function

  # 123456 → "$1,234.56"; negatives in parentheses, as the workbook shows them.
  def money(cents)
    whole, frac = format("%.2f", cents.abs / 100.0).split(".")
    text = "$#{whole.reverse.scan(/\d{1,3}/).join(',').reverse}.#{frac}"
    cents.negative? ? "(#{text})" : text
  end

  # "2026-09" → [Date 2026-09-01, Date 2026-09-30]. Raises on any other shape.
  def month_range(month)
    m = month.to_s.match(/\A(\d{4})-(0[1-9]|1[0-2])\z/) or raise ArgumentError, "month must be YYYY-MM, got #{month.inspect}"
    start = Date.new(m[1].to_i, m[2].to_i, 1)
    [ start, start.end_of_month ]
  end
end
