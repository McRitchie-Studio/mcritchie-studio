require "net/http"
require "uri"
require "json"

module Quickbooks
  # Reads a connected QuickBooks Online company: its CompanyInfo and its
  # ProfitAndLoss report for a date range. Every call is a GET with a bearer
  # access token; the Reader holds no write path, so nothing here can change a
  # company's books. Intuit's error is said plainly ("Intuit answered 403: ...").
  #
  # The API host follows the connection's environment (sandbox or production).
  # Every request names minorversion=75: Intuit retired minor versions 1-74 in
  # August 2025 and serves 75 to anything older, so 75 is the floor and the
  # schema these readers parse.
  #
  # The access token comes from OAuthClient.access_token (one refresh, under
  # the row's lock) the first time a Reader needs it, and lives only as long as
  # the Reader. A caller that already holds a fresh access token (the callback,
  # straight from the code exchange) passes `token:`, `realm_id:` and
  # `environment:` and spends no refresh.
  class Reader
    API_URLS = { "sandbox" => "https://sandbox-quickbooks.api.intuit.com",
                 "production" => "https://quickbooks.api.intuit.com" }.freeze
    MINOR_VERSION = 75

    Company = Struct.new(:name, :legal_name, :country, :fiscal_year_start_month, keyword_init: true)
    # One top-level block of the report: Income, Expenses, NetIncome, ...
    Section = Struct.new(:group, :name, :total, keyword_init: true)
    ProfitAndLoss = Struct.new(:start_date, :end_date, :currency, :basis, :sections, keyword_init: true) do
      def net_income = sections.find { _1.group == "NetIncome" }&.total
      def empty? = sections.empty?
    end

    class << self
      # Stand-in for every read: (url, access_token) -> [status, body]. nil
      # means Intuit itself. Set in tests, the e2e lane and a local demo only.
      attr_accessor :http
    end

    attr_reader :realm_id, :environment

    def initialize(connection = nil, token: nil, realm_id: nil, environment: nil, oauth: OAuthClient)
      raise ArgumentError, "a Reader needs a connection or an access token and realm id" if connection.nil? && (token.nil? || realm_id.blank?)

      @connection = connection
      @token = token
      @realm_id = (realm_id || connection.realm_id).to_s
      @environment = (environment || connection&.environment).to_s
      raise ArgumentError, "unknown QuickBooks environment #{@environment.inspect}" unless API_URLS.key?(@environment)

      @oauth = oauth
    end

    def base_url = "#{API_URLS.fetch(environment)}/v3/company/#{ERB::Util.url_encode(realm_id)}"

    def company_info
      info = get_json("/companyinfo/#{ERB::Util.url_encode(realm_id)}")["CompanyInfo"] || {}
      Company.new(name: info["CompanyName"].presence, legal_name: info["LegalName"].presence,
                  country: info["Country"].presence, fiscal_year_start_month: info["FiscalYearStartMonth"].presence)
    end

    # The ProfitAndLoss report from start_date to end_date (Dates), totals per
    # top-level section. accounting_method: "Accrual" or "Cash"; nil leaves
    # the company's own preference.
    def profit_and_loss(start_date:, end_date:, accounting_method: nil)
      start_date, end_date = start_date.to_date, end_date.to_date
      raise ArgumentError, "the report ends before it starts" if end_date < start_date
      raise ArgumentError, "accounting_method is Accrual or Cash" unless [ nil, "Accrual", "Cash" ].include?(accounting_method)

      query = { start_date: start_date.iso8601, end_date: end_date.iso8601, accounting_method: }.compact
      json = get_json("/reports/ProfitAndLoss", query)
      header = json["Header"] || {}
      options = Array(header["Option"]).to_h { [ _1["Name"], _1["Value"] ] }
      sections = options["NoReportData"] == "true" ? [] : Array(json.dig("Rows", "Row")).filter_map { section(_1) }
      ProfitAndLoss.new(start_date: parse_date(header["StartPeriod"]) || start_date, end_date: parse_date(header["EndPeriod"]) || end_date,
                        currency: header["Currency"].presence, basis: header["ReportBasis"].presence, sections:)
    end

    private

    def section(row)
      cells = row.dig("Summary", "ColData") or return nil
      name = cells.first&.dig("value").presence || row.dig("Header", "ColData", 0, "value").presence || row["group"].to_s
      Section.new(group: row["group"].presence, name:, total: amount(cells.last&.dig("value")))
    end

    def amount(value)
      BigDecimal(value.to_s)
    rescue ArgumentError, TypeError
      nil
    end

    def parse_date(value)
      value.present? ? Date.iso8601(value.to_s) : nil
    rescue Date::Error
      nil
    end

    def token = (@token ||= @oauth.access_token(@connection))

    # The JSON of a 200, or OAuthClient::Error with Intuit's message.
    def get_json(path, query = {})
      url = "#{base_url}#{path}?#{URI.encode_www_form(query.merge(minorversion: MINOR_VERSION))}"
      status, body = get(url, token)
      json = JSON.parse(body.to_s) rescue {}
      json = {} unless json.is_a?(Hash)
      raise OAuthClient::Error, "Intuit answered #{status}: #{fault(json)}" unless status == 200

      json
    end

    def fault(json)
      error = Array((json["Fault"] || json["fault"] || {}).then { _1["Error"] || _1["error"] }).first || {}
      error["Message"] || error["message"] || json["error"] || "no detail"
    end

    def get(url, token)
      return self.class.http.call(url, token) if self.class.http

      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = "application/json"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { _1.request(request) }
      [ response.code.to_i, response.body ]
    rescue *OAuthClient::NETWORK_ERRORS => e
      raise OAuthClient::Error, "Intuit could not be reached: #{e.class}"
    end
  end
end
