# frozen_string_literal: true

module Books
  # Records what one or more lines were: a category from config/books.yml, an
  # optional purpose (how the balance sheet groups distributions), and a note
  # citing who said so. `by` is stamped as classified_by and the moment as
  # classified_at, so the ledger shows whether a rule or a person decided, and
  # when. Passing category nil returns lines to unclassified.
  #
  # The one write path for an answer: `bin/books classify` (Books::Export) and
  # the /books review page (BooksController) both call it, so both refuse the
  # same things (a purpose beside a category that is not a distribution among
  # them).
  #
  # A reclass is a re-classify: a line already booked (say as professional_fees)
  # takes the new category, and its old one is gone from every tab on the next
  # close. Moving a cost to an asset category (deal_costs) capitalizes it.
  module Classify
    Error = Class.new(StandardError)

    module_function

    def call(entity, ids:, category:, by:, purpose: nil, note: nil, config: Books::Config.current)
      raise Error, "say who decided (by:)" if by.to_s.strip.empty?

      kind = config.category(category).kind if category
      # A purpose groups distributions on the balance sheet and means nothing
      # anywhere else, so one given beside another category (or an undo) is
      # refused out loud rather than stored or dropped.
      if purpose.present? && kind != "distribution"
        raise Error, "a purpose is for a distribution only; clear the purpose or pick a distribution"
      end
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

      now = Time.current
      BookEntry.transaction do
        entries.each do |e|
          e.update!(category: category, purpose: category ? purpose.presence : nil,
                    classified_by: category ? by : nil, classified_at: category ? now : nil, note: note.presence || e.note)
        end
      end
      entries
    rescue Books::Config::Error, ArgumentError => e
      raise Error, e.message
    end
  end
end
