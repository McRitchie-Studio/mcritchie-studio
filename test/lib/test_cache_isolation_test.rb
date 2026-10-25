require "test_helper"

# [unit] TestCacheIsolation: a request-local cache an earlier test left open on
# Rails.cache's null store cannot answer a later test's fetch (the
# Tiktok::OAuthClientTokenSourceTest granted-scope flake, hub CI run 40152089339).
class TestCacheIsolationTest < ActiveSupport::TestCase
  teardown { Rails.cache.unset_local_cache }

  test "[unit] the null store answers from a live local cache (the control)" do
    Rails.cache.new_local_cache
    Rails.cache.write("probe", "kept")

    assert_equal "kept", Rails.cache.read("probe"), "a :null_store keeps nothing unless a local cache is live"
  end

  test "[unit] reset! drops a live local cache, and the null store forgets again" do
    Rails.cache.new_local_cache
    Rails.cache.write("probe", "kept")

    assert TestCacheIsolation.reset!
    assert_nil Rails.cache.local_cache
    assert_nil Rails.cache.read("probe")
  end

  test "[unit] reset! with no local cache open is a no-op" do
    assert_not TestCacheIsolation.reset!
    assert_not TestCacheIsolation.reset!(ActiveSupport::Cache::MemoryStore.new), "a store with no local cache"
  end

  # The hook, not just the method: a test case starts clean though one was left open.
  test "[unit] the next test starts with no local cache open" do
    seen = :not_run
    probe = Class.new(ActiveSupport::TestCase) do
      define_method(:test_probe) { seen = Rails.cache.local_cache }
    end
    Minitest::Runnable.runnables.delete(probe)

    Rails.cache.new_local_cache
    Rails.cache.write("probe", "kept")
    result = probe.new(:test_probe).run

    assert result.passed?, result.failures.map(&:message).join("; ")
    assert_nil seen, "the probe test inherited the local cache an earlier test left open"
  end
end
