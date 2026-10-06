require "test_helper"

# [unit] [integration] WHERE RACK::ATTACK KEEPS ITS COUNTS
# (Rack::Attack.counter_store in config/initializers/rack_attack.rb).
#
# Production counts in Solid Cache, in the primary database, so a count made
# by one dyno is seen by every other and survives a deploy. A dyno or a release
# is modelled here as a fresh store object: a per-process store (the file and
# memory stores) starts at zero, and a database-backed one does not.
class RackAttackCounterStoreTest < ActionDispatch::IntegrationTest
  def solid_store
    SolidCache::Store.new
  end

  setup do
    @was_enabled = Rack::Attack.enabled
    @was_store = Rack::Attack.cache.store
    Rack::Attack.enabled = true
  end

  teardown do
    Rack::Attack.cache.store = @was_store
    Rack::Attack.enabled = @was_enabled
  end

  def chat(ip: "203.0.113.41")
    post chat_index_path, params: { message: "" }, as: :json, headers: { "REMOTE_ADDR" => ip }
    response.status
  end

  def fill_chat_window
    Rack::Attack::CHAT_IP_LIMIT.times { assert_equal 401, chat, "under the limit the request reaches the controller" }
  end

  test "[unit] production counts in Solid Cache, everywhere else in Rails.cache" do
    assert_instance_of SolidCache::Store, Rack::Attack.counter_store(ActiveSupport::EnvironmentInquirer.new("production"))
    assert_same Rails.cache, Rack::Attack.counter_store(ActiveSupport::EnvironmentInquirer.new("development"))
    assert_same Rails.cache, Rack::Attack.counter_store(ActiveSupport::EnvironmentInquirer.new("test"))
  end

  test "[unit] the production store keeps its rows in the primary database" do
    assert_nil SolidCache.configuration.connects_to
    assert SolidCache::Entry.table_exists?
  end

  # An expiry thread in a web process would hold a connection past the budget in
  # config/puma.rb; the job runs on the Solid Queue worker, which is budgeted.
  test "[unit] expiry runs as a Solid Queue job, never a web-dyno thread" do
    assert_equal :job, solid_store.expiry_method
  end

  test "[unit] throttle limits and periods are unchanged" do
    expected = {
      "magic_link/ip" => [10, 60], "magic_link/email" => [5, 60], "signup/ip" => [5, 60],
      "sso_continue/ip" => [5, 60], "oauth_callback/ip" => [20, 60],
      "chat/ip" => [10, 60], "chat/user" => [30, 600]
    }
    actual = Rack::Attack.throttles.transform_values { |t| [t.limit, t.period.to_i] }

    assert_equal expected, actual
  end

  test "[integration] a throttle counter persists across a cache store restart" do
    Rack::Attack.cache.store = solid_store
    fill_chat_window

    Rack::Attack.cache.store = solid_store

    assert_equal 429, chat, "a fresh Solid Cache store reads the count the last one wrote"
    assert_equal 401, chat(ip: "203.0.113.42"), "another address is not affected"
  end

  test "[integration] control: a per-process store forgets the count on restart" do
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    fill_chat_window

    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

    assert_equal 401, chat, "the defect the shared store closes: a restart resets the window"
  end
end
