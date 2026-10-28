# frozen_string_literal: true

module Books
  # Reads a Huntington business statement's text (Books::PdfText) into its
  # summary and its lines. It does not decide whether the statement is right;
  # Parsed#problems compares the lines against the bank's own totals, and
  # Books::Intake refuses a statement with any problem, so a line this parser
  # misses can never pass silently into the books.
  #
  # The layout, as the 2026 statements print it (one account per statement):
  #
  #   Huntington Business Checking 100              Account: -------0881
  #   Statement Activity From:      Beginning Balance        $45,000.00
  #   06/01/26 to 06/30/26          Debits (-)                 6,000.00
  #   ...                           Total Service Charges (-)      0.00
  #                                 Ending Balance           $39,000.00
  #   Other Debits (-)                                   Account:-------0881
  #   Date      Amount    Description
  #   06/03     3,000.00  US BANK NA PAYMENT ...
  #   Service Charge Detail                              Account:-------0881
  #   Date  Service Charge (-)  Waives and  Discounts (+)  Description
  #   08/17     50.00           WIRE TRANSFER FEES(OUTGOING)
  #
  # A section header with (+) holds credits and one with (-) holds debits;
  # Service Charge Detail holds charges. Lines carry MM/DD only: the year comes
  # from the statement period (a December line on a January statement is the
  # year before).
  module HuntingtonParser
    Error = Class.new(StandardError)

    Line = Struct.new(:posted_on, :amount_cents, :section, :description, keyword_init: true)

    Parsed = Struct.new(:product, :last4, :period_start, :period_end, :opening_cents, :credits_cents,
                        :debits_cents, :service_charges_cents, :closing_cents, :lines, keyword_init: true) do
      def sum(section) = lines.select { |l| l.section == section }.sum(&:amount_cents)

      # Every way the lines disagree with the bank's own totals. Empty means the
      # statement reconciles.
      def problems
        out = []
        movement = closing_cents - opening_cents
        bank = credits_cents - debits_cents - service_charges_cents
        out << "the summary does not add up: opening + credits − debits − charges ≠ closing" if bank != movement
        out << "credit lines total #{Books.money(sum('credit'))}, the summary says #{Books.money(credits_cents)}" if sum("credit") != credits_cents
        out << "debit lines total #{Books.money(-sum('debit'))}, the summary says #{Books.money(debits_cents)}" if -sum("debit") != debits_cents
        if -sum("service_charge") != service_charges_cents
          out << "charge lines total #{Books.money(-sum('service_charge'))}, the summary says #{Books.money(service_charges_cents)}"
        end
        out
      end
    end

    MONEY = /\$?(\d{1,3}(?:,\d{3})*\.\d{2})/
    PERIOD = %r{(\d{2})/(\d{2})/(\d{2}) to (\d{2})/(\d{2})/(\d{2})}
    ACCOUNT = /Account: ?-+(\d{4})/
    SECTION = /\A\s*(?<name>[A-Z][A-Za-z ]*?)\s*(?:\((?<sign>[+-])\))?\s*(?:\(Continued\))?\s+Account: ?-+\d{4}\s*\z/
    LINE = %r{\A\s*(\d{2})/(\d{2})\s+(\d{1,3}(?:,\d{3})*\.\d{2})(?:\s+(\d{1,3}(?:,\d{3})*\.\d{2}))?\s+(\S.*?)\s*\z}
    # Where a section's lines end even without a new header: page furniture.
    NOISE = /\A\s*(Statement Period from|Investments are offered|The Huntington National|Page \d+ of|Date\s)/

    module_function

    def parse(text)
      text = text.to_s
      period = text.match(PERIOD) or raise Error, "no statement period (MM/DD/YY to MM/DD/YY) in the text"
      start = date(period[3], period[1], period[2])
      finish = date(period[6], period[4], period[5])
      last4 = text[ACCOUNT, 1] or raise Error, "no account number in the text"

      Parsed.new(
        product: text[/^\s*(\S.*?)\s{2,}Account: ?-+\d{4}/, 1],
        last4: last4,
        period_start: start, period_end: finish,
        opening_cents: summary(text, /Beginning Balance\s+#{MONEY}/, required: true),
        credits_cents: summary(text, /(?<!Other )Credits \(\+\)\s+#{MONEY}/),
        debits_cents: summary(text, /(?<!Other )Debits \(-\)\s+#{MONEY}/),
        service_charges_cents: summary(text, /Total Service Charges \(-\)\s+#{MONEY}/),
        closing_cents: summary(text, /Ending Balance\s+#{MONEY}/, required: true),
        lines: lines(text, finish)
      )
    end

    def lines(text, period_end)
      out = []
      section = nil
      text.each_line do |raw|
        raw = raw.chomp
        if raw.include?("\f")
          section = nil
          raw = raw.split("\f").last.to_s
        end
        if (m = raw.match(SECTION))
          section = section_for(m[:name], m[:sign])
          next
        end
        next if section.nil? || raw.strip.empty?

        if (m = raw.match(LINE))
          gross = cents(m[3])
          waived = m[4] ? cents(m[4]) : 0
          amount = section == "credit" ? gross : -(gross - waived)
          out << Line.new(posted_on: line_date(m[1], m[2], period_end), amount_cents: amount,
                          section: section, description: m[5].squeeze(" "))
        elsif raw.match?(NOISE)
          section = nil if raw.match?(/\A\s*(Statement Period from|Investments|The Huntington)/)
        elsif out.any? && raw.match?(/\A\s{8,}\S/)
          out.last.description = "#{out.last.description} #{raw.strip.squeeze(' ')}"
        end
      end
      out
    end

    # credit | debit | service_charge, or nil for a section that holds no lines
    # (Balance Activity, Service Charge Summary).
    def section_for(name, sign)
      return "service_charge" if name.match?(/\AService Charge Detail/i)
      return "credit" if sign == "+"
      return "debit" if sign == "-"

      nil
    end

    def summary(text, pattern, required: false)
      m = text.match(pattern)
      raise Error, "no #{pattern.source[/[A-Za-z ]+/].strip} in the summary" if m.nil? && required

      m ? cents(m[1]) : 0
    end

    def cents(text) = (BigDecimal(text.delete(",")) * 100).to_i

    def date(yy, mm, dd) = Date.new(2000 + yy.to_i, mm.to_i, dd.to_i)

    def line_date(mm, dd, period_end)
      year = mm.to_i > period_end.month ? period_end.year - 1 : period_end.year
      Date.new(year, mm.to_i, dd.to_i)
    end
  end
end
