# frozen_string_literal: true

require "test_helper"
require_relative "../../support/books_fixtures"

# The McRitchie Industries entry in config/books.yml, read from the real file.
# The statement text is synthetic (made-up amounts in the layout Industries'
# Huntington statements print); only the last four digits come from the config.
class BooksIndustriesEntityTest < ActiveSupport::TestCase
  include BooksFixtures

  def config = @config ||= Books::Config.load

  def industries = config.entity("industries")

  def statement(product:, last4:, other_last4:, period:, opening:, credits:, debits:, charges:, closing:, body:)
    <<~TXT
      THE HUNTINGTON NATIONAL BANK
                 MCRITCHIE INDUSTRIES LLC                                              Have a Question or Concern?
      #{product.ljust(70)} Account: -------#{last4}
      Statement Activity From:                   Beginning Balance                       $#{opening}
      #{period}                       Credits (+)                             #{credits}
                                                 Debits (-)                              #{debits}
                                                 Total Service Charges (-)               #{charges}
                                                 Ending Balance                          $#{closing}
      #{body.gsub('OTHER', other_last4).gsub('ACCT', last4)}
      Balance Activity                                                                      Account:-------#{last4}
    TXT
  end

  def money_market_text
    mm = industries.account("money_market")
    statement(product: mm.product, last4: mm.last4, other_last4: industries.account("checking").last4,
              period: "09/01/26 to 09/30/26", opening: "0.00", credits: "250,012.34", debits: "20,000.00",
              charges: "10.00", closing: "230,002.34", body: <<~BODY)
                Other Credits (+)                                                                     Account:-------ACCT
                Date              Amount       Description
                09/02           250,000.00     Transfer Credit
                09/30                12.34     INTEREST PAYMENT
                Other Debits (-)                                                                      Account:-------ACCT
                Date              Amount       Description
                09/25            20,000.00     INTERNET TFR TO CHECKING 092526 XXXXXXXOTHER
                Service Charge Detail                                                                 Account:-------ACCT
                Date      Service Charge (-)     Waives and   Discounts (+)      Description
                09/15                10.00                                       MONTHLY SERVICE FEE
              BODY
  end

  def checking_text
    ck = industries.account("checking")
    statement(product: ck.product, last4: ck.last4, other_last4: industries.account("money_market").last4,
              period: "09/01/26 to 09/30/26", opening: "0.00", credits: "45,000.00", debits: "7,500.00",
              charges: "0.00", closing: "37,500.00", body: <<~BODY)
                Other Credits (+)                                                                     Account:-------ACCT
                Date              Amount       Description
                09/02            25,000.00     Transfer Credit
                09/25            20,000.00     INTERNET TFR FRM CHECKING 092526 XXXXXXXOTHER
                Other Debits (-)                                                                      Account:-------ACCT
                Date              Amount       Description
                09/24             7,500.00     OUTGOING FEDWIRE TRANSFER - MANUAL
              BODY
  end

  # An account's first, empty statement: opened late in August, nothing moved.
  def empty_text(key)
    a = industries.account(key)
    statement(product: a.product, last4: a.last4, other_last4: a.last4, period: "08/26/26 to 08/31/26",
              opening: "0.00", credits: "0.00", debits: "0.00", charges: "0.00", closing: "0.00", body: "")
  end

  # [unit]

  test "the industries entity loads with its own Drive, its own domain's workspace subject, and two Huntington accounts" do
    assert_equal "McRitchie Industries LLC", industries.name
    assert_equal "team@mcritchie.industries", industries.drive_subject
    assert_equal "McRitchie Industries Books", industries.drive_root
    assert_equal config.entity("studio").share_with, industries.share_with
    refute_equal config.entity("studio").drive_root, industries.drive_root, "two entities, two books folders"

    assert_equal %w[checking money_market], industries.accounts.keys.sort
    industries.accounts.each_value do |a|
      assert_equal "huntington", a.bank
      assert_match(/\A\d{4}\z/, a.last4, "#{a.key}: the books carry the last four digits only")
      assert_equal Date.new(2026, 8, 26), a.opened_on, "#{a.key}: opened_on is the first statement's start"
    end
    studio_last4 = config.entity("studio").accounts.values.map(&:last4)
    assert_empty industries.accounts.values.map(&:last4) & studio_last4, "an account belongs to one entity"
  end

  test "each account parses from synthetic statement text and maps back to its entity account" do
    { "money_market" => money_market_text, "checking" => checking_text }.each do |key, text|
      parsed = Books::HuntingtonParser.parse(text)
      assert_empty parsed.problems, "#{key}: #{parsed.problems.join('; ')}"
      assert_equal key, industries.account_for_last4(parsed.last4)&.key
      assert_equal industries.account(key).product, parsed.product
      assert_equal [ Date.new(2026, 9, 1), Date.new(2026, 9, 30) ], [ parsed.period_start, parsed.period_end ]
    end
    empty = Books::HuntingtonParser.parse(empty_text("checking"))
    assert_equal [ [], [], Date.new(2026, 8, 26) ], [ empty.problems, empty.lines, empty.period_start ]
  end

  test "rules classify interest, fees and own-account transfers, and hold every Transfer Credit and wire for an answer" do
    classify = ->(desc, cents) { Books::Categorizer.call(industries, description: desc, amount_cents: cents) }

    assert_equal "interest_income", classify.("INTEREST PAYMENT", 96_00).category
    assert_equal "bank_fees", classify.("MONTHLY SERVICEFEE", -10_00).category
    mm, ck = industries.account("money_market").last4, industries.account("checking").last4
    assert_equal "internal_transfer", classify.("INTERNETTFRTO CHECKING 092526 XXXXXXX#{ck}", -20_000_00).category
    assert_equal "internal_transfer", classify.("INTERNETTFRFRM CHECKING 092526 XXXXXXX#{mm}", 20_000_00).category

    # The Studio inflows print as a bare "Transfer Credit": no sender, so no rule
    # may decide them (Alex McRitchie 2026-10-28: Sep 2's two were member
    # contributions, recorded with bin/books classify at run time).
    inflow = classify.("TransferCredit", 400_000_00)
    assert_nil inflow.category
    assert_equal "rule transfer-credit-needs-answer: needs an answer", inflow.note
    assert_nil classify.("OUTGOINGFEDWIRETRANSFER - MANUAL", -5_500_00).category
    assert_nil classify.("INTERNETTFRTO CHECKING 092526 XXXXXXX9501", -1_00).category, "a Studio account is not Industries' own"
  end

  # [integration]

  test "status, intake, classify and close run for industries against the database" do
    drive = FakeDrive.new
    export = ->(request) { Books::Export.call({ "entity" => "industries" }.merge(request), config: config, drive: drive) }
    files = { "mm-aug" => empty_text("money_market"), "ck-aug" => empty_text("checking"),
              "mm-sep" => money_market_text, "ck-sep" => checking_text }

    status = export.("verb" => "status")
    assert_equal "McRitchie Industries LLC", status["entity"]
    assert_equal [ 0, 0 ], status["accounts"].map { |a| a["statements"] }

    results = Books::Intake.new(industries, drive: drive, text: ->(bytes) { bytes })
                           .call(files: files.map { |name, text| { "name" => "#{name}.pdf", "bytes" => text } })
    assert_equal [ "filed" ] * 4, results.map(&:status), results.map(&:to_h).inspect
    assert_equal [ "industries" ], BookStatement.distinct.pluck(:entity)

    status = export.("verb" => "status")
    assert_equal [ [ 2, "2026-09-30" ] ] * 2, status["accounts"].map { |a| [ a["statements"], a["through"] ] }
    assert_equal 3, status["unclassified"], "two Transfer Credits and one wire"

    inflows = export.("verb" => "unclassified")["lines"].select { |l| l["description"] == "Transfer Credit" }
    assert_equal 2, inflows.size
    export.("verb" => "classify", "ids" => inflows.map { |l| l["id"] }, "category" => "member_contribution",
            "note" => "Alex McRitchie 2026-10-28: initial funds from Studio", "by" => "test")
    wire = export.("verb" => "unclassified")["lines"].sole
    export.("verb" => "classify", "ids" => [ wire["id"] ], "category" => "professional_fees", "note" => "test", "by" => "test")

    closed = export.("verb" => "close", "month" => "2026-09", "by" => "test")
    assert_equal "final", closed["status"], closed.inspect
    assert_equal 0, BookClose.where(entity: "studio").count
  end
end
