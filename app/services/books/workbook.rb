# frozen_string_literal: true

require "caxlsx"

module Books
  # The month-close workbook, as xlsx bytes that Drive converts into a native
  # Sheet. Every figure on the statement tabs is a formula over the Ledger tab,
  # so the Sheet recalculates if anyone edits a line; the only typed-in numbers
  # are the period keys, the accounts' opening balances and the statements'
  # closing balances, each in blue and labelled with its source.
  #
  #   Notes          status (FINAL or DRAFT, and why), checks, lines waiting, statements
  #   P&L            income and expenses by month for the close's year, cash basis
  #   Balance Sheet  cash per account against the statement, and equity by source
  #   Equity         the year's rollforward, tied back to the balance sheet
  #   Ledger         every line since the books began, signed (+ in, − out)
  #
  # FORMULA ESCAPING. caxlsx escapes every "=" cell by default, so bank text can
  # never run as a formula. The Notes and Ledger tabs, which carry statement
  # descriptions, keep that default; only the three statement tabs, whose text
  # is config labels and Books::Classify-checked purposes, turn it off.
  #
  # Contributions and distributions are equity and never reach the P&L. The
  # Ledger's Kind column (income | expense | contribution | distribution |
  # transfer | unclassified) is what every SUMIFS keys on.
  class Workbook
    # Zero shows as a dash. Escaped, not quoted: caxlsx writes format codes into
    # the XML attribute unescaped, and a quote there corrupts styles.xml.
    MONEY = '$#,##0.00;($#,##0.00);\-'
    LEDGER = "Ledger"
    MONTHS = %w[Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec].freeze

    def initialize(entity:, month:, entries:, statements:, checks:, status:, generated_at:, generated_by:,
                   config: Books::Config.current)
      @entity = entity
      @month = month
      @month_start, @month_end = Books.month_range(month)
      @entries = entries
      @statements = statements
      @checks = checks
      @status = status
      @generated_at = generated_at
      @generated_by = generated_by
      @config = config
      @refs = {}
    end

    def to_xlsx = package.to_stream.read

    # The built package, kept so the suite can read the cells before they are
    # serialized (test/support/books_formula_eval.rb).
    def package = @package ||= build_package

    # The figures the formulas should produce, computed here in Ruby from the
    # same lines: what the CLI prints and book_closes.summary keeps, and what
    # the suite holds the formulas to.
    def summary
      ytd = @entries.select { |e| e.posted_on.year == @month_end.year }
      by_kind = ->(list, kind) { list.select { |e| kind_of(e) == kind }.sum(&:amount_cents) }
      income = by_kind.(ytd, "income")
      expense = -by_kind.(ytd, "expense")
      cash = @entity.accounts.values.sum { |a| opening_cents(a) + @entries.select { |e| e.account_key == a.key }.sum(&:amount_cents) }
      {
        "status" => @status, "month" => @month,
        "income_ytd_cents" => income, "expenses_ytd_cents" => expense, "net_income_ytd_cents" => income - expense,
        "cash_cents" => cash, "equity_cents" => cash - by_kind.(@entries, "transfer"),
        "unclassified" => @entries.count { |e| !e.classified? }
      }
    end

    private

    def build_package
      package = Axlsx::Package.new
      package.use_shared_strings = true
      book = package.workbook
      @styles = build_styles(book.styles)
      notes(book)
      pnl(book)
      balance_sheet(book)
      equity(book)
      ledger(book)
      package
    end

    # --- tabs ---------------------------------------------------------------------

    def notes(book)
      book.add_worksheet(name: "Notes") do |ws|
        ws.add_row [ "#{@entity.name}: month close #{@month}" ], style: @styles[:title]
        ws.add_row [ status_line ], style: (@status == "final" ? @styles[:bold] : @styles[:warn])
        ws.add_row [ "Basis: cash. Through #{@month_end.strftime('%B %-d, %Y')}." ]
        ws.add_row [ "Generated #{@generated_at.in_time_zone('America/Denver').strftime('%Y-%m-%d %H:%M %Z')} by #{@generated_by} with bin/books close. A re-run overwrites this Sheet; record changes with bin/books classify, not here." ]
        ws.add_row [ "Ledger amounts are signed: money in is positive, money out negative. Member contributions and distributions are equity and never appear on the P&L." ]
        ws.add_row []
        ws.add_row [ "Check", "Result", "Detail" ], style: @styles[:header]
        @checks.each { |c| ws.add_row [ c.label, c.ok ? "OK" : "OPEN", c.detail ], style: [ nil, (c.ok ? nil : @styles[:warn]), nil ] }
        waiting = @entries.reject(&:classified?)
        if waiting.any?
          ws.add_row []
          ws.add_row [ "Lines waiting for an answer", "Account", "Amount", "Description", "Entry" ], style: @styles[:header]
          waiting.each do |e|
            ws.add_row [ e.posted_on, account_label(e.account_key), e.amount_cents / 100.0, e.description, e.id ],
                       style: [ @styles[:date], nil, @styles[:money], nil, nil ], types: %i[date string float string integer]
          end
        end
        ws.add_row []
        ws.add_row [ "Statement", "Period", "Opening", "Credits", "Debits", "Charges", "Closing" ], style: @styles[:header]
        @statements.each do |s|
          ws.add_row [ account_label(s.account_key), s.period_label, *[ s.opening_cents, s.credits_cents, s.debits_cents,
                                                                         s.service_charges_cents, s.closing_cents ].map { |c| c / 100.0 } ],
                     style: [ nil, nil, *[ @styles[:money_input] ] * 5 ], types: %i[string string float float float float float]
        end
        ws.column_widths 46, 26, 16, 44, 14, 14, 16
      end
    end

    def pnl(book)
      months = (1..@month_end.month).map { |m| [ (@month_end.year * 100) + m, "#{MONTHS[m - 1]} #{@month_end.year}" ] }
      book.add_worksheet(name: "P&L", escape_formulas: false) do |ws|
        ws.add_row [ "#{@entity.name}: profit and loss, #{@month_end.year} (cash basis)" ], style: @styles[:title]
        ws.add_row [ "Through #{@month_end.strftime('%B %-d, %Y')}. #{status_line}" ]
        ws.add_row []
        ws.add_row [ "Category", *months.map(&:last), "Year to date" ], style: @styles[:header]
        ws.add_row [ "Period (YYYYMM)", *months.map(&:first) ], style: @styles[:input]
        period_row = ws.rows.size
        last_col = col(months.size + 1)
        ytd_col = col(months.size + 2)

        section = lambda do |title, kind, sign|
          ws.add_row [ title ], style: @styles[:bold]
          first = ws.rows.size + 1
          @config.categories_of(kind).each do |cat|
            cells = months.each_index.map do |i|
              c = col(i + 2)
              "=#{sign}SUMIFS(#{LEDGER}!$D:$D,#{LEDGER}!$E:$E,$A#{ws.rows.size + 1},#{LEDGER}!$H:$H,#{c}$#{period_row})"
            end
            ws.add_row [ cat.label, *cells, "=SUM(B#{ws.rows.size + 1}:#{last_col}#{ws.rows.size + 1})" ], style: @styles[:money]
          end
          last = ws.rows.size
          total_row = ws.rows.size + 1
          ws.add_row [ "Total #{title.downcase}", *(2..months.size + 2).map { |i| "=SUM(#{col(i)}#{first}:#{col(i)}#{last})" } ],
                     style: @styles[:total]
          total_row
        end

        income_total = section.("Income", "income", "")
        ws.add_row []
        expense_total = section.("Expenses", "expense", "-")
        ws.add_row []
        net_row = ws.rows.size + 1
        ws.add_row [ "Net income", *(2..months.size + 2).map { |i| "=#{col(i)}#{income_total}-#{col(i)}#{expense_total}" } ],
                   style: @styles[:total]
        @refs[:net_income_ytd] = "'P&L'!$#{ytd_col}$#{net_row}"
        ws.column_widths 30, *[ 14 ] * months.size, 16
      end
    end

    def balance_sheet(book)
      book.add_worksheet(name: "Balance Sheet", escape_formulas: false) do |ws|
        ws.add_row [ "#{@entity.name}: balance sheet" ], style: @styles[:title]
        ws.add_row [ "As of #{@month_end.strftime('%B %-d, %Y')} (cash basis). #{status_line}" ]
        ws.add_row []
        ws.add_row [ "Period (YYYYMM)", period_key ], style: [ nil, @styles[:input] ]
        p = "$B$4"
        thru = ->(kind, extra = "") { "SUMIFS(#{LEDGER}!$D:$D,#{LEDGER}!$F:$F,\"#{kind}\"#{extra},#{LEDGER}!$H:$H,\"<=\"&#{p})" }
        ws.add_row []
        ws.add_row [ "Assets", "Books", "Per statement", "Difference" ], style: @styles[:header]
        first = ws.rows.size + 1
        @entity.accounts.each_value do |a|
          r = ws.rows.size + 1
          closing = statement_closing(a)
          ws.add_row [ "Cash: #{a.label}",
                       "=#{opening_cents(a) / 100.0}+SUMIFS(#{LEDGER}!$D:$D,#{LEDGER}!$B:$B,\"#{a.label}\",#{LEDGER}!$H:$H,\"<=\"&#{p})",
                       closing && closing / 100.0, closing ? "=ROUND(B#{r}-C#{r},2)" : "no statement" ],
                     style: [ nil, @styles[:money], @styles[:money_input], @styles[:money] ]
        end
        ws.add_row [ "Transfers in transit between own accounts", "=-#{thru.('transfer')}" ], style: [ nil, @styles[:money] ]
        assets = ws.rows.size + 1
        ws.add_row [ "Total assets", "=SUM(B#{first}:B#{assets - 1})" ], style: @styles[:total]
        ws.add_row []
        ws.add_row [ "Liabilities" ], style: @styles[:header]
        ws.add_row [ "None recorded (cash basis; no liability accounts kept)", 0 ], style: [ nil, @styles[:money_input] ]
        liabilities = ws.rows.size + 1
        ws.add_row [ "Total liabilities", "=B#{liabilities - 1}" ], style: @styles[:total]
        ws.add_row []
        ws.add_row [ "Equity" ], style: @styles[:header]
        efirst = ws.rows.size + 1
        ws.add_row [ "Opening balances (first statements' beginning balances)", total_openings / 100.0 ],
                   style: [ nil, @styles[:money_input] ]
        ws.add_row [ "Member contributions", "=#{thru.('contribution')}" ], style: [ nil, @styles[:money] ]
        distribution_purposes.each do |purpose|
          ws.add_row [ "Member distributions: #{purpose}", "=#{thru.('distribution', ",#{LEDGER}!$G:$G,\"#{purpose}\"")}" ],
                     style: [ nil, @styles[:money] ]
        end
        ws.add_row [ "Unclassified lines (to confirm)", "=#{thru.('unclassified')}" ], style: [ nil, @styles[:money] ]
        ws.add_row [ "Retained earnings (net income to date)", "=#{thru.('income')}+#{thru.('expense')}" ], style: [ nil, @styles[:money] ]
        equity = ws.rows.size + 1
        ws.add_row [ "Total equity", "=SUM(B#{efirst}:B#{equity - 1})" ], style: @styles[:total]
        ws.add_row [ "Total liabilities and equity", "=B#{liabilities}+B#{equity}" ], style: @styles[:total]
        ws.add_row []
        ws.add_row [ "Check: assets − liabilities − equity (must be 0)", "=ROUND(B#{assets}-B#{liabilities}-B#{equity},2)" ],
                   style: [ @styles[:bold], @styles[:money] ]
        @refs[:bs_equity] = "'Balance Sheet'!$B$#{equity}"
        ws.column_widths 52, 18, 18, 14
      end
    end

    def equity(book)
      book.add_worksheet(name: "Equity", escape_formulas: false) do |ws|
        ws.add_row [ "#{@entity.name}: equity rollforward, #{@month_end.year}" ], style: @styles[:title]
        ws.add_row [ "Through #{@month_end.strftime('%B %-d, %Y')}. #{status_line}" ]
        ws.add_row [ "Year starts (YYYYMM)", (@month_end.year * 100) + 1 ], style: [ nil, @styles[:input] ]
        ws.add_row [ "Close period (YYYYMM)", period_key ], style: [ nil, @styles[:input] ]
        ytd = ->(kind, extra = "") { "SUMIFS(#{LEDGER}!$D:$D,#{LEDGER}!$F:$F,\"#{kind}\"#{extra},#{LEDGER}!$H:$H,\">=\"&$B$3,#{LEDGER}!$H:$H,\"<=\"&$B$4)" }
        ws.add_row []
        first = ws.rows.size + 1
        ws.add_row [ "Equity at the start of the year",
                     "=#{total_openings / 100.0}+SUMIFS(#{LEDGER}!$D:$D,#{LEDGER}!$F:$F,\"<>transfer\",#{LEDGER}!$H:$H,\"<\"&$B$3)" ],
                   style: [ nil, @styles[:money] ]
        ws.add_row [ "Net income, year to date", "=#{@refs.fetch(:net_income_ytd)}" ], style: [ nil, @styles[:money] ]
        ws.add_row [ "Member contributions", "=#{ytd.('contribution')}" ], style: [ nil, @styles[:money] ]
        distribution_purposes.each do |purpose|
          ws.add_row [ "Member distributions: #{purpose}", "=#{ytd.('distribution', ",#{LEDGER}!$G:$G,\"#{purpose}\"")}" ],
                     style: [ nil, @styles[:money] ]
        end
        ws.add_row [ "Unclassified lines (to confirm)", "=#{ytd.('unclassified')}" ], style: [ nil, @styles[:money] ]
        close = ws.rows.size + 1
        ws.add_row [ "Equity at month end", "=SUM(B#{first}:B#{close - 1})" ], style: @styles[:total]
        ws.add_row [ "Balance sheet equity", "=#{@refs.fetch(:bs_equity)}" ], style: [ nil, @styles[:money] ]
        ws.add_row [ "Check: rollforward − balance sheet (must be 0)", "=ROUND(B#{close}-B#{close + 1},2)" ],
                   style: [ @styles[:bold], @styles[:money] ]
        ws.column_widths 52, 18
      end
    end

    def ledger(book)
      book.add_worksheet(name: LEDGER) do |ws|
        ws.add_row [ "Date", "Account", "Description", "Amount", "Category", "Kind", "Purpose", "Period", "Entry",
                     "Classified by", "Note" ], style: @styles[:header]
        @entries.each do |e|
          ws.add_row [ e.posted_on, account_label(e.account_key), e.description, e.amount_cents / 100.0, category_label(e),
                       kind_of(e), purpose_of(e), e.period, e.id, e.classified_by.to_s, e.note.to_s ],
                     style: [ @styles[:date], nil, nil, @styles[:money], nil, nil, nil, nil, nil, nil, nil ],
                     types: %i[date string string float string string string integer integer string string]
        end
        ws.sheet_view.pane { |pane| pane.top_left_cell = "A2"; pane.state = :frozen; pane.y_split = 1 }
        ws.column_widths 12, 22, 52, 14, 22, 14, 30, 10, 8, 26, 40
      end
    end

    # --- figures ------------------------------------------------------------------

    def status_line
      return "FINAL: every check passed and every line is classified." if @status == "final"

      "DRAFT: #{@checks.reject(&:ok).map(&:detail).join('; ')}."
    end

    def period_key = (@month_end.year * 100) + @month_end.month

    def kind_of(entry) = entry.classified? ? @config.category(entry.category).kind : "unclassified"

    def category_label(entry) = entry.classified? ? @config.category(entry.category).label : "Unclassified"

    # A distribution always carries a purpose on the sheet, so SUMIFS by purpose
    # adds up to the whole.
    def purpose_of(entry)
      return entry.purpose.to_s unless kind_of(entry) == "distribution"

      entry.purpose.presence || "Unspecified"
    end

    # SUMIFS matches text case-insensitively, so purposes that differ only in
    # case are one row (the first spelling seen), never two rows that each sum both.
    def distribution_purposes
      @entries.select { |e| kind_of(e) == "distribution" }.map { |e| purpose_of(e) }.uniq(&:downcase).sort_by(&:downcase)
    end

    def account_label(key) = @entity.account(key).label

    def opening_cents(account)
      first = @statements.select { |s| s.account_key == account.key }.min_by(&:period_start)
      first ? first.opening_cents : 0
    end

    def total_openings = @entity.accounts.values.sum { |a| opening_cents(a) }

    def statement_closing(account)
      @statements.find { |s| s.account_key == account.key && s.period_start <= @month_end && s.period_end >= @month_end }&.closing_cents
    end

    def col(index) = Axlsx.col_ref(index - 1)

    def build_styles(styles)
      base = { font_name: "Arial", sz: 10 }
      {
        title: styles.add_style(base.merge(b: true, sz: 14)),
        bold: styles.add_style(base.merge(b: true)),
        warn: styles.add_style(base.merge(b: true, fg_color: "B42318")),
        header: styles.add_style(base.merge(b: true, bg_color: "E8EAED", border: { style: :thin, color: "BDC1C6", edges: [ :bottom ] })),
        money: styles.add_style(base.merge(format_code: MONEY)),
        money_input: styles.add_style(base.merge(format_code: MONEY, fg_color: "0000FF")),
        input: styles.add_style(base.merge(fg_color: "0000FF")),
        total: styles.add_style(base.merge(b: true, format_code: MONEY, border: { style: :thin, color: "000000", edges: [ :top ] })),
        date: styles.add_style(base.merge(format_code: "yyyy-mm-dd"))
      }
    end
  end
end
