require "test_helper"
require_relative "../../support/daily_app_report_fixtures"

# [integration] DailyAppReport::Fetcher across a real socket: a tiny HTTP server
# on 127.0.0.1 answers the source contract, so Net::HTTP, the timeouts and the
# status mapping are exercised for real. Nothing reaches a real app.
class DailyAppReport::FetcherTest < ActiveSupport::TestCase
  include DailyAppReportFixtures

  ENDING = Time.find_zone("America/Denver").local(2026, 10, 15, 7)
  PATH = "/_studio/health_report".freeze

  def with_server(answer)
    server = TinyServer.new(PATH => answer)
    yield server
  ensure
    server&.close
  end

  def fetch(server, read_timeout: 2)
    DailyAppReport::Fetcher.new(open_timeout: 1, read_timeout: read_timeout).fetch(server.url, token: "tok-123", ending: ENDING)
  end

  test "[integration] a 200 is parsed, and the request carries the bearer token and the shared window end" do
    with_server([ 200, JSON.generate(health_body(errors: 2)) ]) do |server|
      body = fetch(server)

      assert_equal 1, body["schema"]
      request = server.requests.sole
      assert_equal "Bearer tok-123", request[:headers]["authorization"]
      assert_equal "2026-10-15T07:00:00-06:00", request[:query]["ending"]
    end
  end

  test "[integration] a slow app is a timeout" do
    with_server(:hang) do |server|
      error = assert_raises(DailyAppReport::Fetcher::Error) { fetch(server, read_timeout: 0.3) }
      assert_equal "timeout", error.message
    end
  end

  test "[integration] 401, 404, 5xx and bad JSON each name a short reason and never the token" do
    { [ 401, "{}" ] => "HTTP 401 token mismatch", [ 404, "{}" ] => "HTTP 404 endpoint not deployed",
      [ 503, "down" ] => "HTTP 503", [ 200, "<html>" ] => "bad JSON", [ 200, "[1]" ] => "bad JSON" }.each do |answer, reason|
      with_server(answer) do |server|
        error = assert_raises(DailyAppReport::Fetcher::Error) { fetch(server) }
        assert_equal reason, error.message
        refute_includes error.message, "tok-123"
      end
    end
  end

  test "[integration] a refused connection is unreachable, by error class" do
    server = TinyServer.new({})
    url = server.url
    server.close
    error = assert_raises(DailyAppReport::Fetcher::Error) do
      DailyAppReport::Fetcher.new(open_timeout: 1, read_timeout: 1).fetch(url, token: "t", ending: ENDING)
    end
    assert_equal "ECONNREFUSED", error.message
  end

  test "[unit] the URL is the production URL plus the contract path, trailing slash or not" do
    assert_equal "https://turfmonster.media/_studio/health_report?ending=2026-10-15T07%3A00%3A00-06%3A00",
                 DailyAppReport::Fetcher.uri_for("https://turfmonster.media/", ENDING).to_s
  end
end
