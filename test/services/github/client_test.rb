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
end
