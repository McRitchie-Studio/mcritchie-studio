require "logger"
require "stringio"
require "test_helper"

class Github::ClientTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](key)
      headers[key] || headers[key.to_s.downcase]
    end
  end

  test "adds token auth header without logging the token" do
    requests = []
    log_io = StringIO.new
    client = Github::Client.new(
      token: "secret-token",
      logger: Logger.new(log_io),
      executor: ->(uri, request) {
        requests << [uri, request]
        FakeResponse.new("200", '{"ok":true}', { "x-ratelimit-remaining" => "42" })
      }
    )

    assert_equal({ "ok" => true }, client.get("/rate_limit"))
    assert_equal "Bearer secret-token", requests.first.last["Authorization"]
    assert_not_includes log_io.string, "secret-token"
  end

  test "paginates array responses using link header" do
    responses = [
      FakeResponse.new(
        "200",
        '[{"sha":"one"}]',
        {
          "x-ratelimit-remaining" => "42",
          "link" => '<https://api.github.com/repos/owner/repo/commits?page=2>; rel="next"'
        }
      ),
      FakeResponse.new("200", '[{"sha":"two"}]', { "x-ratelimit-remaining" => "41" })
    ]
    client = Github::Client.new(logger: nil, executor: ->(_uri, _request) { responses.shift })

    records = client.paginate("/repos/owner/repo/commits")

    assert_equal ["one", "two"], records.map { |record| record["sha"] }
  end

  test "retries transient failures" do
    responses = [
      FakeResponse.new("500", '{"message":"temporary"}', {}),
      FakeResponse.new("200", '{"ok":true}', {})
    ]
    sleeps = []
    client = Github::Client.new(
      logger: nil,
      sleeper: ->(seconds) { sleeps << seconds },
      executor: ->(_uri, _request) { responses.shift }
    )

    assert_equal({ "ok" => true }, client.get("/test"))
    assert_equal [1], sleeps
  end

  test "can pause after successful requests" do
    sleeps = []
    client = Github::Client.new(
      logger: nil,
      sleeper: ->(seconds) { sleeps << seconds },
      request_pause_seconds: 0.25,
      executor: ->(_uri, _request) { FakeResponse.new("200", '{"ok":true}', {}) }
    )

    assert_equal({ "ok" => true }, client.get("/test"))
    assert_equal [0.25], sleeps
  end

  test "retries secondary rate limits with configured pause" do
    responses = [
      FakeResponse.new(
        "403",
        '{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}',
        { "x-ratelimit-remaining" => "42" }
      ),
      FakeResponse.new("200", '{"ok":true}', { "x-ratelimit-remaining" => "41" })
    ]
    sleeps = []
    client = Github::Client.new(
      logger: nil,
      sleeper: ->(seconds) { sleeps << seconds },
      rate_limit_pause_seconds: 3,
      rate_limit_retries: 1,
      executor: ->(_uri, _request) { responses.shift }
    )

    assert_equal({ "ok" => true }, client.get("/test"))
    assert_equal [3], sleeps
  end

  test "logs safe rate limit diagnostics without request auth headers" do
    log_io = StringIO.new
    client = Github::Client.new(
      token: "secret-token",
      logger: Logger.new(log_io),
      rate_limit_pause_seconds: 0,
      rate_limit_retries: 0,
      executor: ->(_uri, _request) {
        FakeResponse.new(
          "403",
          '{"message":"You have exceeded a secondary rate limit.","documentation_url":"https://docs.github.com/rest"}',
          {
            "x-ratelimit-remaining" => "24",
            "x-ratelimit-limit" => "30",
            "x-github-request-id" => "REQUEST123",
            "retry-after" => "180"
          }
        )
      }
    )

    assert_raises(Github::Client::RateLimitError) { client.get("/test") }

    assert_includes log_io.string, "status=403"
    assert_includes log_io.string, "x-ratelimit-remaining"
    assert_includes log_io.string, "REQUEST123"
    assert_includes log_io.string, "You have exceeded a secondary rate limit."
    assert_not_includes log_io.string, "secret-token"
  end

  test "raises rate limit error after configured secondary retries" do
    client = Github::Client.new(
      logger: nil,
      rate_limit_pause_seconds: 0,
      rate_limit_retries: 0,
      executor: ->(_uri, _request) {
        FakeResponse.new(
          "403",
          '{"message":"You have exceeded a secondary rate limit. Please wait a few minutes before you try again."}',
          { "x-ratelimit-remaining" => "42" }
        )
      }
    )

    error = assert_raises(Github::Client::RateLimitError) { client.get("/test") }
    assert_includes error.message, "secondary rate limit"
  end
end
