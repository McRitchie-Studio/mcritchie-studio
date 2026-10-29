# frozen_string_literal: true

require "test_helper"
require_relative "../../support/books_fixtures"

# [integration] Books::Intake and Books::Close across their Drive boundary (a
# FakeDrive standing in for Workspace::DriveClient) and the database: the Inbox
# is read once, a statement is filed whole or not at all, rules classify what
# they can, and a close is a DRAFT until every check passes, then FINAL, written
# to the same two Drive files on every run.
class BooksIntakeAndCloseTest < ActiveSupport::TestCase
  include BooksFixtures

  # The fixture statement as the example entity's savings account, its transfer
  # moved into December, and the checking statement that receives it.
  SAVINGS = BooksFixtures::HUNTINGTON_STATEMENT
            .sub("11/30             1,000.00     INTERNETTFRTO CHECKING 113026 XXXXXXX5678",
                 "12/02             1,000.00     INTERNETTFRTO CHECKING 120226 XXXXXXX5678")
  CHECKING = <<~TXT
    Huntington Business Checking 100                                       Account: -------5678
    Statement Activity From:                   Beginning Balance                       $0.00
    12/01/26 to 12/31/26                       Credits (+)                             1,000.00
                                               Ending Balance                          $1,000.00
    Other Credits (+)                                                                     Account:-------5678
    Date              Amount       Description
    12/02             1,000.00     INTERNETTFRFRM CHECKING 120226 XXXXXXX1234
    Balance Activity                                                                      Account:-------5678
  TXT
  TEXT = ->(bytes) { bytes }

  setup do
    @drive = FakeDrive.new(inbox: [ { id: "inbox-1", name: "savings.pdf", bytes: SAVINGS },
                                    { id: "inbox-2", name: "checking.pdf", bytes: CHECKING } ])
    travel_to Time.utc(2027, 1, 5, 15)
  end

  def entity = books_entity(opened: "2026-12-01")

  def intake(**opts) = Books::Intake.new(entity, drive: @drive, text: TEXT, **opts).call

  def close(month = "2026-12") = Books::Close.new(entity, month, drive: @drive, config: books_config).call(generated_by: "test")

  def lender(month = "2026-12") = Books::LenderPackage.new(entity, month, drive: @drive, config: books_config).call(generated_by: "test")

  test "the Inbox is filed once: statements, lines, rules applied, and a copy in Statements/<year>" do
    results = intake

    assert_equal [ "filed", "filed" ], results.map(&:status)
    savings = BookStatement.find_by!(entity: "example", account_key: "savings")
    assert_equal [ "inbox-1", 6 ], [ savings.inbox_file_id, savings.entries.count ]
    assert savings.entries_reconcile?
    assert_equal({ "interest_income" => 1, "bank_fees" => 2, "internal_transfer" => 1, "member_distribution" => 1, nil => 1 },
                 savings.entries.reorder(nil).group(:category).count)
    assert_equal "rule:card-payment", savings.entries.find_by(category: "member_distribution").classified_by
    assert_equal "Acquisition costs", savings.entries.find_by(category: "member_distribution").purpose
    assert_equal "statements/2026", @drive.files.fetch(savings.drive_file_id)[:parent]
    assert_equal "2026-12 Huntington savings 1234.pdf", @drive.files.fetch(savings.drive_file_id)[:name]

    assert_empty intake, "a second run skips every Inbox file it already read"
    assert_equal 2, BookStatement.count
  end

  test "the same statement handed in again is recognised, not filed twice" do
    intake
    again = Books::Intake.new(entity, drive: @drive, text: TEXT).call(files: [ { "name" => "copy.pdf", "bytes" => SAVINGS } ])

    assert_equal [ "already filed" ], again.map(&:status)
    assert_equal 2, BookStatement.count
  end

  test "a statement that does not reconcile is refused whole and nothing of it is recorded" do
    broken = SAVINGS.sub("12/31                50.40     INTEREST PAYMENT\n", "")
    results = Books::Intake.new(entity, drive: @drive, text: TEXT).call(files: [ { "name" => "broken.pdf", "bytes" => broken } ])

    assert_equal "refused", results.first.status
    assert_match(/credit lines total/, results.first.problems.join)
    assert_equal 0, BookStatement.count
    assert_empty @drive.files
  end

  test "a statement for an account the entity does not have is refused" do
    other = CHECKING.gsub("5678", "9999")
    results = Books::Intake.new(entity, drive: @drive, text: TEXT).call(files: [ { "name" => "x.pdf", "bytes" => other } ])

    assert_equal "refused", results.first.status
    assert_match(/not one of example's accounts/, results.first.problems.join)
  end

  test "a close with a line waiting is a DRAFT that says why; answering it makes the re-run FINAL in the same files" do
    intake
    draft = close

    assert_equal "draft", draft.record.status
    assert_equal 1, draft.record.unclassified_count
    assert_equal [ true, true, true, false ], draft.checks.map(&:ok) # coverage, continuity, reconciliation, classified
    assert_equal "Example Studio LLC: 2026-12 close (DRAFT)", @drive.files.fetch(draft.sheet_id)[:name]
    assert_equal Books::Drive::SHEET_MIME, @drive.files.fetch(draft.sheet_id)[:mime]
    assert_equal "closes/2026-12", @drive.files.fetch(draft.pdf_id)[:parent]

    wire = BookEntry.unclassified.sole
    Books::Classify.call(entity, ids: [ wire.id ], category: "member_contribution", by: "alex-mcritchie", config: books_config,
                                       note: "Alex McRitchie 2027-01-05: a contribution")
    final = close

    assert_equal "final", final.record.status
    assert_equal [ draft.sheet_id, draft.pdf_id ], [ final.sheet_id, final.pdf_id ], "a re-run updates the same files"
    assert_equal "Example Studio LLC: 2026-12 close", @drive.files.fetch(final.sheet_id)[:name]
    assert_equal 2, @drive.files.fetch(final.sheet_id)[:revisions]
    assert_equal 1, BookClose.count
    assert_in_delta 50.40 - 60.00, final.summary["net_income_ytd_cents"] / 100.0, 0.001
  end

  test "the lender package needs the close, sits beside it in Drive, matches its figures, and updates its own files" do
    intake
    error = assert_raises(Books::LenderPackage::Error) { lender }
    assert_match(/run bin\/books close example 2026-12 first/, error.message)

    closed = close
    package = lender

    assert_equal "Example Studio LLC: lender package 2026-12 (DRAFT)", @drive.files.fetch(package.sheet_id)[:name]
    assert_equal "closes/2026-12", @drive.files.fetch(package.sheet_id)[:parent]
    assert_equal "closes/2026-12", @drive.files.fetch(package.pdf_id)[:parent]
    refute_includes [ closed.sheet_id, closed.pdf_id ], package.sheet_id, "the package is its own file, not the close's"
    assert_equal [ package.sheet_id, package.pdf_id ], closed.record.reload.values_at(:lender_sheet_file_id, :lender_pdf_file_id)
    Books::LenderPackage::FIGURES.each { |k| assert_equal closed.summary[k], package.summary[k], k }
    assert_empty package.notes
    assert_equal "draft", package.to_h["status"]

    wire = BookEntry.unclassified.sole
    Books::Classify.call(entity, ids: [ wire.id ], category: "member_contribution", by: "alex-mcritchie", config: books_config)
    drifted = lender
    assert_equal [ package.sheet_id, package.pdf_id ], [ drifted.sheet_id, drifted.pdf_id ], "a re-run updates the same files"
    assert_match(/ledger changed since the 2026-12 close ran .*re-run bin\/books close example 2026-12/, drifted.notes.join)

    close
    settled = lender
    assert_empty settled.notes
    assert_equal "final", settled.to_h["status"]
    assert_equal "Example Studio LLC: lender package 2026-12", @drive.files.fetch(settled.sheet_id)[:name]
  end

  test "a missing statement keeps the close a DRAFT and names the account" do
    Books::Intake.new(entity, drive: @drive, text: TEXT).call(files: [ { "name" => "s.pdf", "bytes" => SAVINGS } ])
    result = close

    coverage = result.checks.find { |c| c.key == "coverage" }
    refute coverage.ok
    assert_match(/Checking ···5678/, coverage.detail)
  end

  test "when Drive refuses the update, the close makes new files and says the link changed" do
    intake
    first = close
    @drive.refuse_updates!
    second = close

    refute_equal first.sheet_id, second.sheet_id
    assert_match(/link changed/, second.notes.join)
    assert_equal second.sheet_id, BookClose.sole.sheet_file_id
  end
end
