# frozen_string_literal: true

# THE STAND-IN FOR INTUIT when the QuickBooks connection is walked without an
# Intuit app: the e2e lane (it rides the lane's E2E_FAKE_VIDEO_STORAGE marker,
# as the Fathom, Google and TikTok stand-ins do) and a local demo
# (QUICKBOOKS_STAND_IN=1, development only: a desk's .env also loads under the
# test environment, where the flag would hijack the unit tests). NEVER in
# production.
#
# Intuit's sign-in comes straight back to the callback with the stand-in's code
# and a synthetic realmId. The token and revoke endpoints are stood in at the
# HTTP layer (Quickbooks::OAuthClient.http), so the real exchange, refresh,
# rotation and revoke run. It is stricter than Intuit: it honours only the
# LAST refresh token it issued and answers a new one each time, so a refresh
# that failed to store its new token shows up as invalid_grant on the next read.
#
# The memory is this process's own (the e2e server runs one). The reads answer
# a synthetic company and a small synthetic profit and loss. The callback, the
# stored QuickbooksConnection and the pages are real. The real request shapes
# are pinned by test/services/quickbooks/.
module QuickbooksConnectStandIn
  CODE = "quickbooks-stand-in-code"
  REALM_ID = "9130000000000001"
  COMPANY = "Stand-in Company"

  class SignIn
    def authorize_url(redirect_uri:, state:) = "#{redirect_uri}?#{URI.encode_www_form(code: CODE, state:, realmId: REALM_ID)}"
  end

  # Intuit's token and revoke endpoints: (url, form, headers) -> [status, body].
  class Tokens
    def initialize
      @live = nil
      @lock = Mutex.new
    end

    def call(url, form, _headers)
      @lock.synchronize do
        next revoke(form) if url == Quickbooks::OAuthClient::REVOKE_URL

        case form[:grant_type]
        when "authorization_code"
          next [ 400, { error: "invalid_grant" }.to_json ] unless form[:code] == CODE

          issue
        when "refresh_token"
          next [ 400, { error: "invalid_grant" }.to_json ] unless @live && form[:refresh_token] == @live

          issue
        else [ 400, { error: "unsupported_grant_type" }.to_json ]
        end
      end
    end

    private

    def revoke(form)
      @live = nil if form[:token] == @live
      [ 200, "" ]
    end

    def issue
      @live = "stand-in-refresh-#{SecureRandom.hex(8)}"
      [ 200, { access_token: "stand-in-access-#{SecureRandom.hex(8)}", refresh_token: @live, expires_in: 3600,
               x_refresh_token_expires_in: 8_726_400, token_type: "bearer" }.to_json ]
    end
  end

  READS = lambda do |url, _token|
    path = URI(url).path.delete_prefix("/v3/company/#{REALM_ID}")
    body =
      case path
      when "/companyinfo/#{REALM_ID}"
        { CompanyInfo: { CompanyName: COMPANY, LegalName: "#{COMPANY} LLC", Country: "US", FiscalYearStartMonth: "January" } }
      when "/reports/ProfitAndLoss"
        query = Rack::Utils.parse_query(URI(url).query)
        { Header: { ReportName: "ProfitAndLoss", StartPeriod: query["start_date"], EndPeriod: query["end_date"], Currency: "USD", ReportBasis: "Accrual" },
          Rows: { Row: [
            { Header: { ColData: [ { value: "Income" } ] }, Summary: { ColData: [ { value: "Total Income" }, { value: "1000.00" } ] }, type: "Section", group: "Income" },
            { Header: { ColData: [ { value: "Expenses" } ] }, Summary: { ColData: [ { value: "Total Expenses" }, { value: "400.00" } ] }, type: "Section", group: "Expenses" },
            { Summary: { ColData: [ { value: "Net Income" }, { value: "600.00" } ] }, type: "Section", group: "NetIncome" }
          ] } }
      end
    body ? [ 200, body.to_json ] : [ 400, { Fault: { Error: [ { Message: "the stand-in does not answer #{path}" } ] } }.to_json ]
  end

  def self.install!
    Quickbooks::OAuthClient.sign_in_stand_in = SignIn.new
    Quickbooks::OAuthClient.http = Tokens.new
    Quickbooks::Reader.http = READS
  end
end

if (Rails.env.development? && ENV["QUICKBOOKS_STAND_IN"] == "1") || (Rails.env.test? && ENV["E2E_FAKE_VIDEO_STORAGE"] == "1")
  Rails.application.config.to_prepare { QuickbooksConnectStandIn.install! }
end
