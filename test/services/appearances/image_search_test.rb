require "test_helper"

# [unit] THE IMAGE-SEARCH FAÇADE: which provider serves, what happens when none
# does, and how a provider's failure is contained.
#
# NOTHING HERE TOUCHES THE NETWORK, and that is asserted rather than assumed —
# see `test_no_provider_is_ever_asked_to_search_when_none_is_available` and the
# fakes, none of which can open a socket. The real provider costs money PER QUERY,
# so a suite that could reach it is a suite that can spend.
class Appearances::ImageSearchTest < ActiveSupport::TestCase
  # A PROVIDER THAT NEEDS NO CREDENTIAL. It exists to prove the protocol does not
  # assume one: `available?` is the PROVIDER's question, so a keyless source
  # (Wikimedia Commons answers image queries with no key at all) is selectable
  # without the façade being rewritten. Serper is the only provider that SHIPS
  # today; this fake is the guard that keeps the second one cheap.
  class KeylessProvider
    def self.provider_name = "keyless-fake"
    def self.available? = true
    def self.searched = (@searched ||= [])

    def self.search(query:, limit:)
      searched << [query, limit]
      Appearances::ImageSearch::Answer.new(
        results: [Appearances::ImageSearch::Result.new(image_url: "https://example.com/a.jpg")],
        unparsed_count: 0, provider_name: provider_name
      )
    end
  end

  class UnavailableProvider
    def self.provider_name = "off-fake"
    def self.available? = false
    def self.search(query:, limit:) = raise("an unavailable provider must never be asked to search")
  end

  class ExplodingProvider
    def self.provider_name = "broken-fake"
    def self.available? = true
    def self.search(query:, limit:) = raise(IOError, "connection reset")
  end

  setup { KeylessProvider.searched.clear }

  # THE UNCONFIGURED PATH — the one that actually runs today, because no serper.dev
  # credential exists on any machine or in any Heroku config.
  test "with no provider configured the facade is unavailable and names nobody" do
    Appearances::ImageSearch.stub(:providers, [UnavailableProvider]) do
      refute Appearances::ImageSearch.available?
      assert_nil Appearances::ImageSearch.provider
      assert_nil Appearances::ImageSearch.provider_name
    end
  end

  # AN EMPTY ANSWER, NOT AN EXCEPTION. The page must render from the headshot floor
  # with an honest note; a raise here would turn "we have not bought a search key
  # yet" into a 500 on a page whose job is to show what we already have.
  test "an unconfigured search answers empty rather than raising" do
    Appearances::ImageSearch.stub(:providers, [UnavailableProvider]) do
      answer = Appearances::ImageSearch.search(query: "Josh Allen")

      assert_equal [], answer.results
      assert_equal 0, answer.unparsed_count
    end
  end

  test "no provider is ever asked to search when none is available" do
    # UnavailableProvider#search raises if called at all, so reaching the assertion
    # below is itself the proof that the façade stopped at `available?`.
    Appearances::ImageSearch.stub(:providers, [UnavailableProvider]) do
      assert_equal [], Appearances::ImageSearch.search(query: "Josh Allen").results
    end
  end

  # THE POINT OF THE `available?` PROTOCOL. A provider with no credential at all is
  # selected and served — nothing in the façade asks about an API key.
  test "a provider needing no credential is selected and serves the query" do
    Appearances::ImageSearch.stub(:providers, [KeylessProvider]) do
      assert Appearances::ImageSearch.available?
      assert_equal "keyless-fake", Appearances::ImageSearch.provider_name

      answer = Appearances::ImageSearch.search(query: "Josh Allen", limit: 7)

      assert_equal 1, answer.results.length
      assert_equal [["Josh Allen", 7]], KeylessProvider.searched
    end
  end

  test "the first available provider in the registry wins" do
    Appearances::ImageSearch.stub(:providers, [UnavailableProvider, KeylessProvider]) do
      assert_equal "keyless-fake", Appearances::ImageSearch.provider_name
    end
  end

  # A SEARCH IS AN ENRICHMENT OF A LIST THAT ALREADY HAS A FLOOR. A provider outage
  # costs the operator some photographs; it must never cost them the page.
  test "a provider that raises is contained, not propagated" do
    Appearances::ImageSearch.stub(:providers, [ExplodingProvider]) do
      answer = nil
      assert_nothing_raised { answer = Appearances::ImageSearch.search(query: "Josh Allen") }

      assert_equal [], answer.results
      assert_equal "broken-fake", answer.provider_name,
                   "a contained failure must still say WHO failed, or the log names nobody"
    end
  end

  # THE REAL PROVIDER, ASKED THE ONLY QUESTION THAT IS FREE.
  #
  # `available?` reads ENV and nothing else — no round-trip — which is what lets the
  # page ask it on every render without buying anything. A provider that validated
  # its key here would charge for a page view.
  test "the shipped provider decides availability from its env var alone" do
    # `with_env` (test_helper) restores the original value, which matters under CI's
    # process-per-worker parallelism: a leaked key here would make a sibling test
    # believe a provider is configured.
    with_env("SERPER_API_KEY", nil) do
      refute Appearances::ImageSearch::Serper.available?
    end

    with_env("SERPER_API_KEY", "test-key-not-a-real-credential") do
      assert Appearances::ImageSearch::Serper.available?
    end
  end

  # `provider_name` RATHER THAN `name`. Overriding Class#name makes a class lie to
  # every reflective reader it has, and the protocol gains nothing from it.
  test "the provider does not overwrite its own class name" do
    assert_equal "serper", Appearances::ImageSearch::Serper.provider_name
    assert_equal "Appearances::ImageSearch::Serper", Appearances::ImageSearch::Serper.name
  end
end
