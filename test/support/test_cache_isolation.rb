# frozen_string_literal: true

# Every test starts with no request-local cache on Rails.cache.
#
# The test environment's store is :null_store, so a fetch never answers from an
# earlier one. That holds only while no LOCAL cache is live: NullStore carries
# ActiveSupport::Cache::Strategy::LocalCache, and the app's middleware stack opens
# one per request (LocalCache::Middleware) and closes it when the response BODY is
# closed. A test that calls the Rack stack itself and drops the body leaves that
# local cache live on the thread, and from then on Rails.cache.fetch answers from
# memory in every later test that worker runs.
#
# That is how hub CI run 40152089339 (shard 1, seed 38070) failed
# Tiktok::OAuthClientTokenSourceTest's granted-scope case: an earlier
# CanonicalHostWiringTest request left the local cache open, the test's first
# refresh cached a grant naming video.publish, and the second refresh, which
# names only drafting scopes, was answered from that cache, so MissingScope was
# never raised. The same leak answered the env-pair cases from a grant cached by
# a previous test. Callers should still close what they open (that test now
# does); this reset means one that forgets cannot reach the next test.
module TestCacheIsolation
  module_function

  # Drops a local cache left live on this thread. Returns whether one was.
  def reset!(cache = Rails.cache)
    return false unless cache.respond_to?(:local_cache) && cache.local_cache

    cache.unset_local_cache
    true
  end
end
