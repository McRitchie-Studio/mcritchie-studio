# frozen_string_literal: true

module Books
  # Records what one or more lines were: a category from config/books.yml, an
  # optional purpose (how the balance sheet groups distributions), and a note
  # citing who said so. `by` is stamped as classified_by, so the ledger shows
  # whether a rule or a person decided. Passing category nil returns lines to
  # unclassified.
  module Classify
    Error = Class.new(StandardError)

    module_function

    def call(entity, ids:, category:, by:, purpose: nil, note: nil, config: Books::Config.current)
      raise Error, "say who decided (by:)" if by.to_s.strip.empty?

      config.category(category) if category
      # A purpose becomes a row label and a quoted SUMIFS criterion on the
      # workbook, so it may not start a formula, close the quote, or carry a
      # character SUMIFS reads as a wildcard (* ? ~) or a comparison (< > =).
      if purpose.to_s.match?(/\A\s*[=+\-@]|["*?~<>=]/)
        raise Error, "a purpose may not start with + - @ or contain \" * ? ~ < > =: #{purpose.inspect}"
      end
      ids = Array(ids).map { |i| Integer(i) }
      entries = BookEntry.for_entity(entity.key).where(id: ids).to_a
      missing = ids - entries.map(&:id)
      raise Error, "no #{entity.key} line(s) #{missing.join(', ')}" if missing.any?

      BookEntry.transaction do
        entries.each do |e|
          e.update!(category: category, purpose: category ? purpose.presence : nil,
                    classified_by: category ? by : nil, note: note.presence || e.note)
        end
      end
      entries
    rescue Books::Config::Error, ArgumentError => e
      raise Error, e.message
    end
  end
end
