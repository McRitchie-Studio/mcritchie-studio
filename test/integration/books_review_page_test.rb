# frozen_string_literal: true

require "test_helper"
require "securerandom"

# [integration] /books: the review-and-confirm page. Admin-only; it lists the
# lines waiting for an answer with their date, account (last four only),
# amount, description and rule hint; Save records the answer through
# Books::Classify with the signed-in admin as `by` and refuses what the CLI
# refuses; recent answers carry who and when, and Undo returns a line.
#
# The lines are synthetic, on the real `studio` entity's configured accounts
# (config/books.yml), because the page reads Books::Config.current.
class BooksReviewPageTest < ActionDispatch::IntegrationTest
  def admin
    @admin ||= User.create!(email: "books-admin@example.com", name: "Books Admin", role: "admin")
  end

  setup do
    statement = BookStatement.create!(entity: "studio", account_key: "checking", period_start: Date.new(2026, 9, 1),
                                      period_end: Date.new(2026, 9, 30), opening_cents: 10_000_00, credits_cents: 0,
                                      debits_cents: 3_500_00, closing_cents: 6_500_00, source_sha256: SecureRandom.hex(32))
    @wire = statement.entries.create!(entity: "studio", account_key: "checking", position: 0, posted_on: Date.new(2026, 9, 24),
                                      amount_cents: -3_000_00, section: "debit",
                                      description: "OUTGOING FEDWIRETRANSFER BNF ACCT 123456789012",
                                      note: "rule wire-needs-answer: needs an answer")
    @fee = statement.entries.create!(entity: "studio", account_key: "checking", position: 1, posted_on: Date.new(2026, 9, 25),
                                     amount_cents: -500_00, section: "debit", description: "SOMETHING NEW",
                                     note: "no rule matched; needs an answer")
  end

  test "[integration] anonymous and non-admin visitors are turned away, and cannot classify" do
    get books_path
    assert_response :redirect

    log_in_as(User.create!(email: "books-member@example.com", name: "Member"))
    get books_path
    assert_response :redirect
    patch book_entry_path(entity: "studio", id: @wire.id), params: { category: "bank_fees" }
    assert_response :redirect
    assert_nil @wire.reload.category, "a non-admin must not record an answer"
  end

  test "[integration] the page lists each waiting line with its account's last four only" do
    log_in_as(admin)
    get books_path(entity: "studio")
    assert_response :success

    assert_select "[data-test='books-line'][data-entry-id='#{@wire.id}']" do
      assert_select "[data-test='books-line-account']", "Checking ···0881"
      assert_select "[data-test='books-line-amount']", "($3,000.00)"
      assert_select "[data-test='books-line-description']", "OUTGOING FEDWIRETRANSFER BNF ACCT ···9012"
      assert_select "[data-test='books-line-hint']", /wire-needs-answer/
      assert_select "select[name='category'] optgroup[label='Assets (capitalized)'] option[value='deal_costs'][data-kind='asset']"
      assert_select "select[name='category'] option[value='member_distribution'][data-kind='distribution']"
      assert_select "input[name='purpose'][list='books-purposes']"
    end
    assert_no_match(/123456789012/, response.body, "a full account number must never reach the page")
    assert_select "[data-test='books-entity-industries']"
  end

  test "[integration] Save records the answer through Books::Classify with the admin as by, and Undo returns it" do
    log_in_as(admin)
    patch book_entry_path(entity: "studio", id: @wire.id),
          params: { category: "member_distribution", purpose: "Owner draws", note: "Alex McRitchie 2026-10-28: a draw" }
    assert_redirected_to books_path(entity: "studio")
    @wire.reload
    assert_equal [ "member_distribution", "Owner draws", "books-admin@example.com", "Alex McRitchie 2026-10-28: a draw" ],
                 [ @wire.category, @wire.purpose, @wire.classified_by, @wire.note ]
    assert @wire.classified_at, "the moment of the answer is recorded"

    follow_redirect!
    assert_select "[data-test='books-line'][data-entry-id='#{@wire.id}']", count: 0
    assert_select "[data-test='books-recent-line'][data-entry-id='#{@wire.id}']" do
      assert_select "[data-test='books-recent-category']", "Member distribution"
      assert_select "[data-test='books-recent-by']", /by books-admin@example\.com/
    end

    patch book_entry_path(entity: "studio", id: @wire.id), params: { category: "none" }
    assert_redirected_to books_path(entity: "studio")
    @wire.reload
    assert_equal [ nil, nil, nil, nil ], [ @wire.category, @wire.purpose, @wire.classified_by, @wire.classified_at ]
  end

  test "[integration] a purpose typed beside a category that is not a distribution is dropped" do
    log_in_as(admin)
    patch book_entry_path(entity: "studio", id: @fee.id), params: { category: "bank_fees", purpose: "Owner draws" }
    assert_equal [ "bank_fees", nil ], [ @fee.reload.category, @fee.purpose ]
  end

  test "[integration] Save refuses what bin/books classify refuses, and an empty pick, and says why" do
    log_in_as(admin)
    patch book_entry_path(entity: "studio", id: @fee.id), params: { category: "member_distribution", purpose: "=HYPERLINK(1)" }
    assert_redirected_to books_path(entity: "studio", anchor: "line-#{@fee.id}")
    assert_match(/a purpose may not start with/, flash[:alert])
    assert_nil @fee.reload.category

    patch book_entry_path(entity: "studio", id: @fee.id), params: { category: "" }
    assert_match(/pick a category/, flash[:alert])

    patch book_entry_path(entity: "studio", id: @fee.id), params: { category: "not_a_category" }
    assert_match(/no category/, flash[:alert])
    assert_nil @fee.reload.category
    assert_equal 0, ErrorLog.where("message LIKE ?", "%purpose%").count, "a refusal is an answer, not a fault"
  end

  test "[integration] another entity's line cannot be classified through this entity, and an unknown entity is a 404" do
    log_in_as(admin)
    patch book_entry_path(entity: "industries", id: @wire.id), params: { category: "bank_fees" }
    assert_match(/no industries line/, flash[:alert])
    assert_nil @wire.reload.category

    get books_path(entity: "nope")
    assert_response :not_found
  end
end
