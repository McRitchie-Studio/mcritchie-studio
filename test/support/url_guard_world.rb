# frozen_string_literal: true

# THE ENGINE'S URL GUARD, WITH ITS LOOKUPS DECIDED BY THE TEST.
#
# The engine looks a URL's host name up, and raises
# Studio::ImageCache::UnresolvedSourceHost (a subclass of InvalidSourceURL)
# when the lookup fails. It does no DNS under a Rails test environment, so a
# test that cares about lookups stands in for the guard here.
#
#   with_url_guard(unresolved: %w[dead.example.com]) do |lookups|
#     ...
#     assert_equal %w[cdn.example.com], lookups
#   end
#
# The stand-in runs the REAL guard first, on the text only (so text refusals
# stay the engine's), then records the host as one lookup, then fails the hosts
# named `unresolved` with the engine's own error. `lookups` therefore holds one
# entry per lookup the engine would make. A call with `resolver: nil` is the
# engine's "judge the text only" and records nothing. No real DNS, no real HTTP.
module UrlGuardWorld
  def with_url_guard(unresolved: [], slow: {}, &block)
    lookups = []
    real = Studio::ImageCache.method(:validate_source_url!)
    guard = lambda do |url, **options|
      uri = real.call(url, resolver: nil)
      next uri if options.key?(:resolver) && options[:resolver].nil?

      host = uri.host.to_s.downcase
      lookups << host
      UrlGuardWorld.advance(slow[host]) if slow[host]
      if unresolved.include?(host)
        raise Studio::ImageCache::UnresolvedSourceHost, "URL host #{host.inspect} could not be resolved: test"
      end

      uri
    end
    Studio::ImageCache.stub(:validate_source_url!, guard) { block.call(lookups) }
  end

  # A clock a test can move, for the memo's age cap and the lookup budget.
  def with_guard_clock(start = 1_000.0)
    UrlGuardWorld.now = start
    Appearances::FetchableUrl.stub(:clock, -> { UrlGuardWorld.now }) { yield }
  ensure
    UrlGuardWorld.now = nil
  end

  class << self
    attr_accessor :now

    def advance(seconds) = self.now = now.to_f + seconds
  end
end
