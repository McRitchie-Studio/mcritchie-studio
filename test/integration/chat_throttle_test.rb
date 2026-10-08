require "test_helper"
require_relative "../support/throttle_clock"

# [integration] POST /chat is throttled per address and per signed-in user. Every
# message costs an Anthropic call and signup is open, so no address and no account
# may run the endpoint unbounded. The suite runs with Rack::Attack off and a null
# cache, so these cases switch both on for their own requests only. A blank message
# answers 422 before the responder runs (a visitor's answers 401 before that), which
# keeps every call offline.
class ChatThrottleTest < ActionDispatch::IntegrationTest
  include ThrottleClock

  setup do
    start_throttle_period(Rack::Attack::CHAT_IP_PERIOD, Rack::Attack::CHAT_USER_PERIOD)
    @was_enabled = Rack::Attack.enabled
    @was_store = Rack::Attack.cache.store
    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  end

  teardown do
    Rack::Attack.cache.store = @was_store
    Rack::Attack.enabled = @was_enabled
  end

  def chat(ip:)
    post chat_index_path, params: { message: "" }, as: :json, headers: { "REMOTE_ADDR" => ip }
  end

  test "[integration] one address is cut off after CHAT_IP_LIMIT posts a minute" do
    Rack::Attack::CHAT_IP_LIMIT.times do
      chat(ip: "203.0.113.7")
      assert_response :unauthorized, "under the limit the request reaches the controller"
    end

    chat(ip: "203.0.113.7")

    assert_response :too_many_requests
    assert_equal Rack::Attack::CHAT_IP_PERIOD.to_i.to_s, response.headers["Retry-After"]
    assert_match "Too many requests", response.parsed_body["error"]

    chat(ip: "203.0.113.8")
    assert_response :unauthorized, "another address is not affected"
  end

  test "[integration] one signed-in user is cut off across addresses after CHAT_USER_LIMIT posts" do
    log_in_as(users(:alex)) # /chat sits behind the admin wall

    Rack::Attack::CHAT_USER_LIMIT.times do |i|
      chat(ip: "198.51.100.#{i + 1}")
      assert_response :unprocessable_entity, "under the limit the request reaches the controller"
    end

    chat(ip: "198.51.100.250")

    assert_response :too_many_requests
    assert_equal Rack::Attack::CHAT_USER_PERIOD.to_i.to_s, response.headers["Retry-After"]
  end

  test "[integration] visitors' posts count against their addresses, never one shared user key" do
    (Rack::Attack::CHAT_USER_LIMIT + 1).times do |i|
      chat(ip: "192.0.2.#{i + 1}")
      assert_response :unauthorized, "a visitor on a fresh address is not throttled by a nil user"
    end
  end

  test "[integration] GET /chat is not throttled" do
    (Rack::Attack::CHAT_IP_LIMIT + 1).times { get chat_index_path, headers: { "REMOTE_ADDR" => "203.0.113.9" } }
    assert_not_equal 429, response.status
  end
end
