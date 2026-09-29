require "test_helper"

class Artists::Wikidata::ClientTest < ActiveSupport::TestCase
  Response = Struct.new(:code, :body, :headers) do
    def [](name) = headers.to_h[name]
  end

  # Serves canned responses in order and records waits instead of sleeping.
  class ScriptedClient < Artists::Wikidata::Client
    attr_reader :waits, :calls

    def initialize(responses, **opts)
      super(pause: 0, **opts)
      @responses = responses
      @waits = []
      @calls = 0
    end

    private

    def post(_query)
      @calls += 1
      next_up = @responses.shift
      next_up.is_a?(Class) ? raise(next_up) : next_up
    end

    def sleep(seconds) = @waits << seconds
  end

  OK = Response.new("200", { results: { bindings: [{ x: 1 }] } }.to_json, {})

  test "retries a throttled or timed-out request, honouring Retry-After" do
    client = ScriptedClient.new([Response.new("429", "", { "Retry-After" => "30" }), Net::ReadTimeout, OK])

    assert_equal [{ "x" => 1 }], client.select("SELECT")
    assert_equal 3, client.calls
    assert_equal [30, 10], client.waits
  end

  test "gives up after the last attempt and on a non-retryable status" do
    client = ScriptedClient.new(Array.new(2) { Response.new("503", "", {}) }, attempts: 2)
    error = assert_raises(Artists::Wikidata::Client::Error) { client.select("SELECT") }
    assert_match "HTTP 503 after 2 attempts", error.message

    client = ScriptedClient.new([Response.new("400", "bad query", {})])
    assert_raises(Artists::Wikidata::Client::Error) { client.select("SELECT") }
    assert_equal 1, client.calls
  end
end
