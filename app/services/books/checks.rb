# frozen_string_literal: true

module Books
  # What must be true before a month close may call itself final. Each check
  # names what it found, so the Notes tab and the operator see the same reasons.
  #
  #   coverage        every account open by month end has a statement reaching it
  #   continuity      each account's statements chain: no gap, and each opens where the last closed
  #   reconciliation  each statement's lines add up to its movement
  #   classified      no line through month end is waiting for an answer
  class Checks
    Check = Struct.new(:key, :label, :ok, :detail, keyword_init: true) do
      def to_h = { "key" => key, "label" => label, "ok" => ok, "detail" => detail }
    end

    def initialize(entity, month)
      @entity = entity
      @month_start, @month_end = Books.month_range(month)
    end

    def call = [ coverage, continuity, reconciliation, classified ]

    def statements
      @statements ||= BookStatement.for_entity(@entity.key).where(period_start: ..@month_end).order(:account_key, :period_start).to_a
    end

    private

    def open_accounts = @entity.accounts.values.select { |a| a.opened_on <= @month_end }

    def coverage
      missing = open_accounts.reject do |a|
        statements.any? { |s| s.account_key == a.key && s.period_end >= @month_end && s.period_start <= [ @month_start, a.opened_on ].max }
      end
      Check.new(key: "coverage", label: "A statement covers the month for every open account", ok: missing.empty?,
                detail: missing.empty? ? "#{open_accounts.size} account(s) covered" : "missing: #{missing.map(&:label).join(', ')}")
    end

    def continuity
      issues = statements.group_by(&:account_key).flat_map do |key, list|
        list.each_cons(2).flat_map do |prev, nxt|
          out = []
          out << "#{key}: gap #{prev.period_end} → #{nxt.period_start}" if prev.period_end + 1 < nxt.period_start
          out << "#{key}: #{nxt.period_label} opens #{Books.money(nxt.opening_cents)}, prior closed #{Books.money(prev.closing_cents)}" if prev.closing_cents != nxt.opening_cents
          out
        end
      end
      first_gaps = open_accounts.filter_map do |a|
        first = statements.find { |s| s.account_key == a.key }
        "#{a.key}: first statement starts #{first.period_start}, account opened #{a.opened_on}" if first && first.period_start > a.opened_on
      end
      issues += first_gaps
      Check.new(key: "continuity", label: "Each account's statements chain without gaps", ok: issues.empty?,
                detail: issues.empty? ? "#{statements.size} statement(s) chain" : issues.join("; "))
    end

    def reconciliation
      bad = statements.reject(&:entries_reconcile?)
      Check.new(key: "reconciliation", label: "Every statement's lines add up to its balances", ok: bad.empty?,
                detail: bad.empty? ? "all reconcile" : bad.map { |s| "#{s.account_key} #{s.period_label}" }.join("; "))
    end

    def classified
      count = BookEntry.for_entity(@entity.key).through(@month_end).unclassified.count
      Check.new(key: "classified", label: "Every line is classified", ok: count.zero?,
                detail: count.zero? ? "none waiting" : "#{count} line(s) need an answer (bin/books unclassified #{@entity.key})")
    end
  end
end
