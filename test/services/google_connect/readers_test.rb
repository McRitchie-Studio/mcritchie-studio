require "test_helper"
require "support/google_connect_fakes"

# [unit] GoogleConnect::CalendarReader, GmailReader and DriveReader: each
# GETs its own API with a fresh bearer token, maps Google's answer, and says
# Google's error plainly. Google is a stand-in throughout.
class GoogleConnect::ReadersTest < ActiveSupport::TestCase
  include GoogleConnectFakes

  teardown { reset_google_connect }

  def connection(scope = SCOPE) = store_google(scope:)

  # Every read starts with a refresh-token exchange answering this access token.
  def fresh_token = google_answers(200, { access_token: "ya29.fresh" })

  test "[unit] the calendar reader GETs the primary calendar with a bearer token and maps events" do
    with_connect_env do
      conn = connection
      fresh_token
      google_reads(GoogleConnect::CalendarReader::EVENTS_URL => [ 200, { items: [
        { id: "e1", summary: "Lender call", start: { dateTime: "2026-10-14T15:00:00Z" }, end: { dateTime: "2026-10-14T16:00:00Z" },
          attendees: [ {}, {} ], hangoutLink: "https://meet.google.com/x" },
        { id: "e2", start: { date: "2026-10-15" }, end: { date: "2026-10-16" } }
      ] } ])

      events = GoogleConnect::CalendarReader.new(conn).events(from: Time.utc(2026, 10, 14), to: Time.utc(2026, 10, 21))

      assert_equal "ya29.fresh", read_requests.last[1]
      query = Rack::Utils.parse_query(URI(read_requests.last[0]).query)
      assert_equal "true", query["singleEvents"]
      assert_equal "2026-10-14T00:00:00Z", query["timeMin"]
      assert_equal [ "Lender call", "(no title)" ], events.map(&:title)
      assert_equal 2, events.first.attendees
      refute events.first.all_day
      assert events.last.all_day
    end
  end

  test "[unit] a refused calendar read raises with Google's message" do
    with_connect_env do
      conn = connection
      fresh_token
      google_reads(GoogleConnect::CalendarReader::EVENTS_URL => [ 403, { error: { message: "Insufficient Permission" } } ])

      error = assert_raises(GoogleConnect::OAuthClient::Error) { GoogleConnect::CalendarReader.new(conn).events }
      assert_equal "Google Calendar answered 403: Insufficient Permission", error.message
    end
  end

  test "[unit] the gmail reader lists the newest ids, then reads each one's headers only" do
    with_connect_env do
      conn = connection(GMAIL)
      fresh_token
      google_reads(
        "#{GoogleConnect::GmailReader::MESSAGES_URL}/m1" => [ 200, { id: "m1", internalDate: "1792000000000", snippet: "Rates &amp; terms",
                                                                     payload: { headers: [ { name: "Subject", value: "Term sheet" }, { name: "From", value: "Lender <l@example.com>" } ] } } ],
        "#{GoogleConnect::GmailReader::MESSAGES_URL}/m2" => [ 200, { id: "m2", payload: { headers: [] } } ],
        GoogleConnect::GmailReader::MESSAGES_URL => [ 200, { resultSizeEstimate: 201, messages: [ { id: "m1" }, { id: "m2" } ] } ]
      )

      inbox = GoogleConnect::GmailReader.new(conn).newest(limit: 5)

      assert_equal 201, inbox.estimate
      assert_equal [ "Term sheet", "(no subject)" ], inbox.messages.map(&:subject)
      assert_equal "Lender <l@example.com>", inbox.messages.first.from
      assert_equal "Rates & terms", inbox.messages.first.snippet, "Google's snippet, unescaped"
      assert_equal "", inbox.messages.last.snippet
      assert_equal Time.at(1_792_000_000).utc, inbox.messages.first.received_at
      list, first = read_requests.map(&:first)
      assert_equal "5", Rack::Utils.parse_query(URI(list).query)["maxResults"]
      assert_equal "metadata", Rack::Utils.parse_query(URI(first).query)["format"], "headers only, never a body"
      assert read_requests.all? { _1[1] == "ya29.fresh" }
    end
  end

  test "[unit] a disabled Gmail API is said plainly" do
    with_connect_env do
      conn = connection(GMAIL)
      fresh_token
      google_reads(GoogleConnect::GmailReader::MESSAGES_URL => [ 403, { error: { message: "Gmail API has not been used in project 1 before or it is disabled." } } ])

      error = assert_raises(GoogleConnect::OAuthClient::Error) { GoogleConnect::GmailReader.new(conn).newest }
      assert_equal "Gmail answered 403: Gmail API has not been used in project 1 before or it is disabled.", error.message
    end
  end

  test "[unit] the drive reader lists the newest files by name, type and change time" do
    with_connect_env do
      conn = connection(DRIVE)
      fresh_token
      google_reads(GoogleConnect::DriveReader::FILES_URL => [ 200, { files: [
        { id: "f1", name: "Q3 plan", mimeType: "application/vnd.google-apps.document", modifiedTime: "2026-10-14T15:00:00Z" },
        { id: "f2", mimeType: "image/png" }
      ] } ])

      files = GoogleConnect::DriveReader.new(conn).newest

      assert_equal [ "Q3 plan", "(untitled)" ], files.map(&:name)
      assert_equal Time.utc(2026, 10, 14, 15), files.first.modified_at
      assert_nil files.last.modified_at
      query = Rack::Utils.parse_query(URI(read_requests.last[0]).query)
      assert_equal "modifiedTime desc", query["orderBy"]
      assert_equal "5", query["pageSize"]
      assert_equal "files(id,name,mimeType,modifiedTime)", query["fields"]
    end
  end

  test "[unit] a read that cannot reach Google says which product, never raising the network error" do
    with_connect_env do
      conn = connection(DRIVE)
      fresh_token
      GoogleConnect::Reader.http = ->(_url, _token) { raise OpenSSL::SSL::SSLError, "synthetic" }

      error = assert_raises(GoogleConnect::OAuthClient::Error) { GoogleConnect::DriveReader.new(conn).newest }
      assert_equal "Google Drive could not be reached: OpenSSL::SSL::SSLError", error.message
    end
  end
end
