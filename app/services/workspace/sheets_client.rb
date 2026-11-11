# frozen_string_literal: true

require "json"
require "net/http"

module Workspace
  # Edits a live Google Sheet in place through the Sheets API, as one Workspace
  # account (domain-wide delegation, the same credential as DriveClient). In place
  # means no rebuild: a person's edits, and any script bound to the sheet, are
  # never at risk.
  #
  # The token holds `drive.file`, which the Sheets API honours: the client edits
  # only spreadsheets this app created, exactly like DriveClient. No new scope.
  #
  # The API must be enabled on the credential's Google Cloud project. Until it is,
  # every call raises Disabled, naming the console page that turns it on.
  #
  #   sheets = Workspace::SheetsClient.new(subject: "team@mcritchie.studio")
  #   sheets.batch_update(id, [SheetsClient.checkboxes(sheet_id: 0, rows: 8...999, column: 9)])
  class SheetsClient
    BASE = "https://sheets.googleapis.com/v4/spreadsheets"

    class Error < StandardError; end

    # The Sheets API is switched off on the credential's project.
    class Disabled < Error; end

    def initialize(subject:, credentials: Credentials, http: nil)
      @subject = subject
      @credentials = credentials
      @http = http
    end

    # The spreadsheet's tabs: [{ title:, sheet_id: }].
    def tabs(spreadsheet_id)
      body = request(:get, "#{BASE}/#{spreadsheet_id}?fields=sheets.properties(sheetId,title)")
      Array(body["sheets"]).map { |s| { title: s.dig("properties", "title"), sheet_id: s.dig("properties", "sheetId") } }
    end

    def sheet_id(spreadsheet_id, title)
      tab = tabs(spreadsheet_id).find { |t| t[:title] == title } or raise Error, "no tab #{title.inspect} in #{spreadsheet_id}"
      tab[:sheet_id]
    end

    # Applies a list of Sheets API requests in one atomic batchUpdate.
    def batch_update(spreadsheet_id, requests)
      return {} if requests.empty?

      request(:post, "#{BASE}/#{spreadsheet_id}:batchUpdate", { requests: requests })
    end

    # Real checkboxes (BOOLEAN validation) on one column, rows as a 0-based,
    # end-exclusive range, the way the API counts. An .xlsx import drops
    # checkboxes, which is why they are applied here, after the upload.
    def self.checkboxes(sheet_id:, rows:, column:)
      { setDataValidation: { range: grid(sheet_id, rows, column),
                             rule: { condition: { type: "BOOLEAN" }, strict: true, showCustomUi: true } } }
    end

    def self.grid(sheet_id, rows, column)
      { sheetId: sheet_id, startRowIndex: rows.begin, endRowIndex: rows.end, startColumnIndex: column, endColumnIndex: column + 1 }
    end

    private

    def request(verb, url, payload = nil)
      uri = URI(url)
      headers = { "Authorization" => "Bearer #{token}", "Content-Type" => "application/json" }
      status, body = (@http || method(:net_http)).call(verb, uri, headers, payload && JSON.generate(payload))
      parsed = body.to_s.empty? ? {} : JSON.parse(body)
      return parsed if status.to_i.between?(200, 299)

      raise Disabled, disabled_message(parsed) if status.to_i == 403 && body.to_s.include?("SERVICE_DISABLED")

      raise Error, "Sheets API #{verb.upcase} #{uri.path} → #{status}: #{parsed.dig('error', 'message') || body.to_s[0, 300]}"
    end

    def disabled_message(parsed)
      project = parsed.dig("error", "details")&.filter_map { |d| d.dig("metadata", "consumer") }&.first.to_s.delete_prefix("projects/")
      "the Google Sheets API is off on the credential's project #{project}. Turn it on: " \
        "https://console.cloud.google.com/apis/library/sheets.googleapis.com?project=#{project}"
    end

    def token
      @token ||= @credentials.authorizer_for(@subject).tap(&:fetch_access_token!).access_token
    end

    def net_http(verb, uri, headers, body)
      Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |h|
        req = (verb == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri, headers)
        req.body = body if body
        res = h.request(req)
        [res.code, res.body]
      end
    end
  end
end
