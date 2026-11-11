# frozen_string_literal: true

require "test_helper"

# [unit] Workspace::SheetsClient: the requests it sends for an in-place edit,
# and the plain error it raises while the Sheets API is still off.
class Workspace::SheetsClientTest < ActiveSupport::TestCase
  FakeAuth = Struct.new(:access_token) { def fetch_access_token! = self }
  FakeCredentials = Struct.new(:subjects) do
    def authorizer_for(subject)
      subjects << subject
      FakeAuth.new("tok")
    end
  end

  def client(responses)
    calls = []
    http = lambda do |verb, uri, headers, body|
      calls << [verb, uri.to_s, headers["Authorization"], body && JSON.parse(body)]
      responses.shift
    end
    creds = FakeCredentials.new([])
    [Workspace::SheetsClient.new(subject: "team@mcritchie.studio", credentials: creds, http: http), calls, creds]
  end

  test "a checkbox column is one setDataValidation BOOLEAN request in a batchUpdate" do
    sheets, calls, creds = client([["200", "{}"]])
    sheets.batch_update("sheet1", [Workspace::SheetsClient.checkboxes(sheet_id: 7, rows: 8...999, column: 4)])
    verb, url, auth, body = calls.sole
    assert_equal [:post, "https://sheets.googleapis.com/v4/spreadsheets/sheet1:batchUpdate", "Bearer tok"], [verb, url, auth]
    req = body["requests"].sole["setDataValidation"]
    assert_equal({ "sheetId" => 7, "startRowIndex" => 8, "endRowIndex" => 999, "startColumnIndex" => 4, "endColumnIndex" => 5 }, req["range"])
    assert_equal "BOOLEAN", req.dig("rule", "condition", "type")
    assert_equal ["team@mcritchie.studio"], creds.subjects, "it acts as the recipe's Workspace account"
  end

  test "tabs and sheet_id read the spreadsheet's tab list" do
    sheets, calls, = client([["200", JSON.generate(sheets: [{ properties: { sheetId: 0, title: "Overview" } }, { properties: { sheetId: 42, title: "Cards" } }])]] * 2)
    assert_equal 42, sheets.sheet_id("s", "Cards")
    assert_match %r{/spreadsheets/s\?fields=sheets\.properties}, calls.first[1]
    assert_raises(Workspace::SheetsClient::Error) { sheets.sheet_id("s", "Nope") }
  end

  test "an empty batch sends nothing" do
    sheets, calls, = client([])
    assert_equal({}, sheets.batch_update("s", []))
    assert_empty calls
  end

  test "while the API is off, the error says where to turn it on" do
    off = { error: { code: 403, status: "PERMISSION_DENIED", message: "Google Sheets API has not been used...",
                     details: [{ reason: "SERVICE_DISABLED", metadata: { consumer: "projects/999864627557" } }] } }
    sheets, = client([["403", JSON.generate(off)]])
    err = assert_raises(Workspace::SheetsClient::Disabled) { sheets.batch_update("s", [{ x: 1 }]) }
    assert_includes err.message, "https://console.cloud.google.com/apis/library/sheets.googleapis.com?project=999864627557"
  end

  test "any other failure names the call and Google's message" do
    sheets, = client([["404", JSON.generate(error: { message: "Requested entity was not found." })]])
    err = assert_raises(Workspace::SheetsClient::Error) { sheets.batch_update("s", [{ x: 1 }]) }
    assert_match(/POST .*s:batchUpdate → 404: Requested entity was not found/, err.message)
  end
end
