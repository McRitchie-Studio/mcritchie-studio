# Stand-ins for Intuit's token, revoke and QuickBooks read endpoints, for tests
# of the QuickBooks connection (QuickbooksConnection, Quickbooks::*). No test
# here reaches Intuit. Every id, name and figure is synthetic.
module QuickbooksConnectFakes
  CREDS = { "INTUIT_CLIENT_ID" => "test-intuit-id", "INTUIT_CLIENT_SECRET" => "test-intuit-secret" }.freeze
  REALM = "1234500000000001".freeze

  def with_quickbooks_env(creds: true, environment: nil)
    names = CREDS.keys + [ Quickbooks::OAuthClient::ENVIRONMENT_ENV ]
    originals = names.index_with { |k| ENV[k] }
    CREDS.each { |k, v| creds ? ENV[k] = v : ENV.delete(k) }
    environment ? ENV[Quickbooks::OAuthClient::ENVIRONMENT_ENV] = environment : ENV.delete(Quickbooks::OAuthClient::ENVIRONMENT_ENV)
    yield
  ensure
    originals&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def quickbooks_grant(refresh_token: "qbo-synthetic-refresh", access_token: "qbo-synthetic-access", refresh_expires_in: 8_726_400)
    { access_token:, refresh_token:, expires_in: 3600, x_refresh_token_expires_in: refresh_expires_in, token_type: "bearer" }
  end

  def store_quickbooks(realm_id: REALM, company_name: "Synthetic Co", environment: "sandbox", refresh_token: "qbo-synthetic-refresh")
    QuickbooksConnection.store!(quickbooks_grant(refresh_token:).transform_keys(&:to_s), realm_id:, company_name:, environment:, by: "alex")
  end

  # Answers every token or revoke POST with `answers` in turn ([status, body
  # Hash or String] each; the last repeats), and records each URL, form and headers.
  def quickbooks_tokens(*answers)
    quickbooks_token_requests.clear
    answers = [ [ 200, quickbooks_grant ] ] if answers.empty?
    Quickbooks::OAuthClient.http = lambda do |url, form, headers|
      quickbooks_token_requests << { url:, form:, headers: }
      status, body = answers.size > 1 ? answers.shift : answers.first
      [ status, body.is_a?(String) ? body : JSON.generate(body) ]
    end
  end

  def quickbooks_token_requests = (@quickbooks_token_requests ||= [])

  # Answers every read GET by the first matching path prefix under the
  # company ({ "/companyinfo" => [status, body Hash] }), and records each URL and token.
  def quickbooks_reads(routes)
    quickbooks_read_requests.clear
    Quickbooks::Reader.http = lambda do |url, token|
      quickbooks_read_requests << [ url, token ]
      path = URI(url).path.sub(%r{\A/v3/company/[^/]+}, "")
      status, body = routes.find { |prefix, _| path.start_with?(prefix) }&.last || [ 404, { Fault: { Error: [ { Message: "unrouted" } ] } } ]
      [ status, JSON.generate(body) ]
    end
  end

  def quickbooks_read_requests = (@quickbooks_read_requests ||= [])

  COMPANY_INFO = { CompanyInfo: { CompanyName: "Synthetic Co", LegalName: "Synthetic Co LLC", Country: "US", FiscalYearStartMonth: "January" },
                   time: "2026-11-06T10:00:00-07:00" }.freeze
  PROFIT_AND_LOSS = {
    Header: { ReportName: "ProfitAndLoss", ReportBasis: "Accrual", StartPeriod: "2026-01-01", EndPeriod: "2026-11-06", Currency: "USD",
              Option: [ { Name: "NoReportData", Value: "false" } ] },
    Columns: { Column: [ { ColTitle: "", ColType: "Account" }, { ColTitle: "Total", ColType: "Money" } ] },
    Rows: { Row: [
      { Header: { ColData: [ { value: "Income" }, { value: "" } ] },
        Rows: { Row: [ { ColData: [ { value: "Sales", id: "1" }, { value: "150.00" } ], type: "Data" } ] },
        Summary: { ColData: [ { value: "Total Income" }, { value: "150.00" } ] }, type: "Section", group: "Income" },
      { Header: { ColData: [ { value: "Expenses" }, { value: "" } ] },
        Summary: { ColData: [ { value: "Total Expenses" }, { value: "40.50" } ] }, type: "Section", group: "Expenses" },
      { Summary: { ColData: [ { value: "Net Income" }, { value: "109.50" } ] }, type: "Section", group: "NetIncome" }
    ] }
  }.freeze

  # Every read the admin page makes, answered.
  def quickbooks_reads_answer_everything
    quickbooks_reads("/companyinfo" => [ 200, COMPANY_INFO ], "/reports/ProfitAndLoss" => [ 200, PROFIT_AND_LOSS ])
  end

  def reset_quickbooks_connect
    Quickbooks::OAuthClient.http = nil
    Quickbooks::OAuthClient.sign_in_stand_in = nil
    Quickbooks::Reader.http = nil
  end
end
