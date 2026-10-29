# frozen_string_literal: true

require "test_helper"
require_relative "../../support/books_fixtures"

# [integration] Books::Export, the dyno half of bin/books, over the database and
# a FakeDrive; and Books::Reminder, the 5th-of-the-month nudge, over the same
# records and a recording deliverer.
class BooksExportAndReminderTest < ActiveSupport::TestCase
  include BooksFixtures

  setup do
    @drive = FakeDrive.new
    book_statement!(account: "savings", from: "2026-01-01", to: "2026-01-31", opening: 0, lines: [
      [ "2026-01-05", 5_000_00, "INCOMING FEDWIRETRANSFER", nil, nil ],
      [ "2026-01-31", 12_00, "INTEREST PAYMENT", "interest_income", nil ]
    ])
  end

  def export(request) = Books::Export.call({ "entity" => "example" }.merge(request), config: books_config, drive: @drive)

  test "status, unclassified, classify and close answer through one request hash" do
    assert_equal 1, export("verb" => "status")["unclassified"]
    line = export("verb" => "unclassified")["lines"].sole
    assert_equal [ "$5,000.00", "savings" ], line.values_at("amount", "account")

    classified = export("verb" => "classify", "ids" => [ line["id"] ], "category" => "member_contribution", "by" => "alex", "note" => "gift")
    assert_equal "member_contribution", classified["classified"].sole["category"]

    closed = export("verb" => "close", "month" => "2026-01", "by" => "alex")
    assert_equal "final", closed["status"], "January: only savings was open, and every line is answered"
    assert_match %r{\Ahttps://drive.google.com/open\?id=}, closed["sheet"]
  end

  test "lender answers an error before the close exists, then its links; status shows each close's cash and lender package" do
    assert_no_difference -> { ErrorLog.count } do
      assert_match(/run bin\/books close example 2026-01 first/, export("verb" => "lender", "month" => "2026-01", "by" => "mack")["error"])
    end
    export("verb" => "close", "month" => "2026-01", "by" => "mack")
    package = export("verb" => "lender", "month" => "2026-01", "by" => "mack")
    assert_match %r{\Ahttps://drive.google.com/open\?id=}, package["pdf"]

    status = export("verb" => "status")
    assert_equal "2026-01-05", status["oldest_waiting"]
    assert_equal [ 5_012_00, package["sheet"] ], status["closes"].sole.values_at("cash_cents", "lender_sheet")
  end

  test "a write without a who, or an unknown entity, is an error answer, not a raise" do
    assert_match(/--by/, export("verb" => "close", "month" => "2026-01")["error"])
    assert_match(/no entity/, Books::Export.call({ "entity" => "nope", "verb" => "status" }, config: books_config, drive: @drive)["error"])
    assert_match(/unknown verb/, export("verb" => "delete")["error"])
  end

  test "a fault, unlike a mistyped argument, leaves an ErrorLog receipt" do
    broken = Object.new
    def broken.inbox_pdfs = raise(Google::Apis::ServerError, "backendError")

    answer = nil
    assert_difference -> { ErrorLog.count }, 1 do
      answer = Books::Export.call({ "entity" => "example", "verb" => "status" }, config: books_config, drive: broken)
    end
    assert_match(/backendError \(recorded in \/error_logs\)/, answer["error"])
    assert_no_difference -> { ErrorLog.count } do
      export("verb" => "close", "month" => "2026-1", "by" => "alex")
    end
  end

  test "the reminder names each open account's statement, in or missing, once per entity and month" do
    sent = []
    deliver = ->(key, content:, idempotency_key:) { sent << [ key, content, idempotency_key ] }
    reminder = Books::Reminder.new(config: books_config, today: Date.new(2026, 2, 5), deliver: deliver, drive_for: ->(_) { @drive })
    reminder.call

    key, content, idempotency = sent.sole
    assert_equal "books_reminder", key
    assert_equal "books_reminder:example:2026-01", idempotency
    assert_includes content, "January 2026 is not closed yet"
    assert_includes content, "Savings ···1234: statement in"
    refute_includes content, "Checking", "an account opened after the month is not asked for"
    assert_includes content, "1 line(s) waiting"
    # The SOP the post cites is Mack's since 2026-10-28, and the path must resolve.
    sop = content[%r{docs/agents/\S+?\.md}]
    assert_equal "docs/agents/agents/mack/sops/close-the-month.md", sop
    assert File.file?(Rails.root.join(sop)), "the reminder cites a file that exists"
    assert_includes content, "ask Mack, the CFO"
  end

  test "a month already closed FINAL posts nothing" do
    BookClose.create!(entity: "example", month: "2026-01", status: "final")
    sent = []
    Books::Reminder.new(config: books_config, today: Date.new(2026, 2, 5), deliver: ->(*a, **k) { sent << a },
                        drive_for: ->(_) { @drive }).call

    assert_empty sent
  end

  test "books_reminder is a registered report destination" do
    assert_includes ReportDestinations.registrations.map(&:key), Books::Reminder::REPORT_KEY
  end
end
