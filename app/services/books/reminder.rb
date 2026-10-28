# frozen_string_literal: true

module Books
  # The 5th-of-the-month nudge: for each entity whose last month is not closed
  # FINAL, say which accounts' statements are in and which are missing, and
  # where to drop them. Delivered to the Discord channel Alex McRitchie picks for
  # `books_reminder` (/admin/report_destinations), once per entity and month.
  # A month already closed FINAL posts nothing.
  class Reminder
    REPORT_KEY = "books_reminder"

    def initialize(config: Books::Config.current, today: Date.current, deliver: ReportDestinations.method(:deliver),
                   drive_for: ->(entity) { Books::Drive.new(entity) })
      @config = config
      @today = today
      @deliver = deliver
      @drive_for = drive_for
    end

    # The month the reminder is about: the one before today's.
    def month = (@today.beginning_of_month - 1).strftime("%Y-%m")

    def call
      @config.entities.filter_map do |entity|
        next if BookClose.find_by(entity: entity.key, month: month)&.final?

        @deliver.call(REPORT_KEY, content: message(entity), idempotency_key: "#{REPORT_KEY}:#{entity.key}:#{month}")
      end
    end

    def message(entity)
      _start, finish = Books.month_range(month)
      lines = entity.accounts.values.select { |a| a.opened_on <= finish }.map do |a|
        have = BookStatement.for_entity(entity.key).exists?(account_key: a.key, period_end: finish..)
        "• #{a.label}: #{have ? 'statement in' : 'statement missing'}"
      end
      inbox = begin
        Books::Drive.link(@drive_for.call(entity).inbox)
      rescue StandardError => e
        "the Inbox folder (Drive unreachable: #{e.class})"
      end
      waiting = BookEntry.for_entity(entity.key).through(finish).unclassified.count
      [
        "**#{entity.name} books: #{finish.strftime('%B %Y')} is not closed yet.**",
        *lines,
        ("• #{waiting} line(s) waiting for an answer" if waiting.positive?),
        "Download the missing statements and drop them in #{inbox}, then ask an agent to run close-the-month " \
        "(docs/agents/modules/close-the-month.md)."
      ].compact.join("\n")
    end
  end
end
