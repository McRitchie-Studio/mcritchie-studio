require "test_helper"
require "support/quickbooks_connect_fakes"

# [unit] Quickbooks::Reader: CompanyInfo and the ProfitAndLoss report, each a
# GET with the bearer token one refresh answered, on the host the connection's
# environment names, at minorversion 75. Intuit is a stand-in throughout, and
# every figure is synthetic.
class Quickbooks::ReaderTest < ActiveSupport::TestCase
  include QuickbooksConnectFakes

  teardown { reset_quickbooks_connect }

  def reader(environment: "sandbox")
    with_quickbooks_env { quickbooks_tokens([ 200, quickbooks_grant(access_token: "a-page") ]) }
    Quickbooks::Reader.new(store_quickbooks(environment:))
  end

  test "[unit] reader pulls company info and profit and loss read-only, with one refresh" do
    quickbooks_reads_answer_everything
    r = reader

    company = with_quickbooks_env { r.company_info }
    assert_equal "Synthetic Co", company.name
    assert_equal "US", company.country

    report = r.profit_and_loss(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 11, 6), accounting_method: "Accrual")
    assert_equal Date.new(2026, 1, 1), report.start_date
    assert_equal Date.new(2026, 11, 6), report.end_date
    assert_equal "USD", report.currency
    assert_equal "Accrual", report.basis
    assert_equal %w[Income Expenses NetIncome], report.sections.map(&:group)
    assert_equal [ "Total Income", "Total Expenses", "Net Income" ], report.sections.map(&:name)
    assert_equal BigDecimal("150.00"), report.sections.first.total
    assert_equal BigDecimal("109.50"), report.net_income

    base = "https://sandbox-quickbooks.api.intuit.com/v3/company/#{REALM}"
    assert_equal [ "#{base}/companyinfo/#{REALM}?minorversion=75",
                   "#{base}/reports/ProfitAndLoss?start_date=2026-01-01&end_date=2026-11-06&accounting_method=Accrual&minorversion=75" ],
                 quickbooks_read_requests.map(&:first)
    assert_equal [ "a-page" ], quickbooks_read_requests.map(&:last).uniq, "every read carries the one refreshed token"
    assert_equal 1, quickbooks_token_requests.size, "one refresh per Reader"
  end

  test "[unit] a production connection reads the production host" do
    quickbooks_reads_answer_everything
    reader(environment: "production").company_info

    assert quickbooks_read_requests.sole.first.start_with?("https://quickbooks.api.intuit.com/v3/company/#{REALM}/companyinfo/")
  end

  test "[unit] the Reader has no write path: every request is a GET through the read seam" do
    assert_empty Quickbooks::Reader.public_instance_methods(false) - %i[company_info profit_and_loss base_url realm_id environment]
    source = File.read(Rails.root.join("app/services/quickbooks/reader.rb"))
    assert_no_match(/Net::HTTP::(Post|Put|Patch|Delete)/, source)
  end

  test "[unit] a report with no data has no sections; the company's own basis is kept when none is asked" do
    quickbooks_reads("/reports/ProfitAndLoss" => [ 200, { Header: { Option: [ { Name: "NoReportData", Value: "true" } ] }, Rows: {} } ])
    report = reader.profit_and_loss(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 31))

    assert report.empty?
    assert_nil report.net_income
    assert_equal Date.new(2026, 1, 1), report.start_date, "falls back to the asked period"
    assert_no_match(/accounting_method/, quickbooks_read_requests.sole.first)
  end

  test "[unit] a backwards range or an unknown basis is refused before Intuit is asked" do
    quickbooks_reads_answer_everything
    r = reader
    assert_raises(ArgumentError) { r.profit_and_loss(start_date: Date.new(2026, 2, 1), end_date: Date.new(2026, 1, 1)) }
    assert_raises(ArgumentError) { r.profit_and_loss(start_date: Date.new(2026, 1, 1), end_date: Date.new(2026, 1, 2), accounting_method: "Both") }
    assert_empty quickbooks_read_requests
  end

  test "[unit] a reader given an access token spends no refresh" do
    quickbooks_reads_answer_everything
    quickbooks_tokens
    Quickbooks::Reader.new(token: "from-exchange", realm_id: REALM, environment: "sandbox").company_info

    assert_empty quickbooks_token_requests
    assert_equal "from-exchange", quickbooks_read_requests.sole.last
  end

  test "[unit] a reader needs a realm and a known environment" do
    assert_raises(ArgumentError) { Quickbooks::Reader.new(token: "t") }
    assert_raises(ArgumentError) { Quickbooks::Reader.new(token: "t", realm_id: REALM, environment: "staging") }
  end

  test "[unit] Intuit's fault is said plainly" do
    quickbooks_reads("/companyinfo" => [ 403, { Fault: { Error: [ { Message: "ApplicationAuthorizationFailed", code: "003100" } ], type: "SERVICE" } } ])

    error = assert_raises(Quickbooks::OAuthClient::Error) { reader.company_info }
    assert_equal "Intuit answered 403: ApplicationAuthorizationFailed", error.message
  end
end
