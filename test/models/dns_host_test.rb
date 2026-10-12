require "test_helper"

# [unit] DnsHost — who serves a domain's DNS, read from its nameservers through
# an injected resolver. No test here reaches real DNS.
class DnsHostTest < ActiveSupport::TestCase
  # The nameservers the 2026-10-12 brief recorded for each production domain.
  ZONES = {
    "mcritchie.studio" => %w[michelle.ns.cloudflare.com. lamar.ns.cloudflare.com.],
    "turfmonster.media" => %w[howard.ns.cloudflare.com. tegan.ns.cloudflare.com.],
    "mcritchie.industries" => %w[nsa1.squarespacedns.com. nsa2.squarespacedns.com.],
    "commercialwelding.llc" => %w[nsa1.squarespacedns.com. nsa4.squarespacedns.com.],
    "karenmcritchie.com" => %w[ns1psw.name.com. ns2kry.name.com.],
    "elsewhere.io" => %w[ns1.dnsimple.net.]
  }.freeze

  setup do
    @queries = []
    DnsHost.resolver = lambda do |name|
      @queries << name
      ZONES.fetch(name, [])
    end
  end

  teardown { DnsHost.reset_resolver! }

  test "the suite arms the no-live-DNS trap, so the default resolver answers nothing" do
    assert_equal "DNS_HOST_NO_LIVE_CALLS", DnsHost::NO_LIVE_CALLS_ENV, "test_helper spells this literal"
    assert_equal "1", ENV[DnsHost::NO_LIVE_CALLS_ENV]
    DnsHost.reset_resolver!

    assert DnsHost.lookup("mcritchie.studio").unknown?, "no stub, no DNS: unknown"
  end

  test "classifies Cloudflare, Squarespace (and legacy Google Domains), name.com and others" do
    assert_equal "cloudflare", DnsHost.classify(%w[lamar.ns.cloudflare.com.])
    assert_equal "squarespace", DnsHost.classify(%w[nsa3.squarespacedns.com])
    assert_equal "squarespace", DnsHost.classify(%w[ns-cloud-a1.googledomains.com.])
    assert_equal "name_com", DnsHost.classify(%w[ns3cpr.name.com.])
    assert_equal "other", DnsHost.classify(%w[ns1.dnsimple.net.])
    assert_equal "unknown", DnsHost.classify([])
    assert_equal "other", DnsHost.classify(%w[ns.cloudflare.com.evil.example]), "the pattern is anchored at the end"
  end

  test "reads the domain from a production URL, dropping www., path and port" do
    assert_equal "commercialwelding.llc", DnsHost.domain_for("https://www.commercialwelding.llc")
    assert_equal "mcritchie.studio", DnsHost.domain_for("https://mcritchie.studio/up")
    assert_equal "cyvasse.xyz", DnsHost.domain_for("Cyvasse.xyz:443")
    assert_nil DnsHost.domain_for(nil)
    assert_nil DnsHost.domain_for("  ")
  end

  test "the brief's current truth: studio and turf on Cloudflare, industries and welding on Squarespace" do
    hosts = DnsHost.lookup_many(%w[https://mcritchie.studio https://turfmonster.media
                                   https://www.mcritchie.industries https://www.commercialwelding.llc
                                   https://karenmcritchie.com])

    assert_equal %w[cloudflare cloudflare squarespace squarespace name_com], hosts.values.map(&:key)
    assert_equal "Cloudflare", hosts["mcritchie.studio"].label
    assert_equal "Squarespace", hosts["commercialwelding.llc"].label
    assert_equal "name.com", hosts["karenmcritchie.com"].label
    assert_equal %w[nsa1.squarespacedns.com nsa4.squarespacedns.com], hosts["commercialwelding.llc"].nameservers
  end

  test "another host is named by its nameserver's own domain" do
    assert_equal "dnsimple.net", DnsHost.lookup("elsewhere.io").label
  end

  test "a subdomain with no delegation walks up to its zone" do
    host = DnsHost.lookup("https://10and5.mcritchie.studio")

    assert host.cloudflare?
    assert_equal "mcritchie.studio", host.domain
    assert_equal %w[10and5.mcritchie.studio mcritchie.studio], @queries
  end

  test "it never queries a bare TLD" do
    host = DnsHost.lookup("nowhere.example")

    assert host.unknown?
    assert_equal %w[nowhere.example], @queries
  end

  test "a timeout or resolver error fails soft to unknown" do
    [ Resolv::ResolvTimeout, Resolv::ResolvError, Errno::ENETUNREACH, Timeout::Error ].each do |error|
      DnsHost.resolver = ->(_name) { raise error }
      host = DnsHost.lookup("turfmonster.media")

      assert host.unknown?, "#{error} must read as unknown, not raise"
      assert_equal "Unknown", host.label
      assert_equal "turfmonster.media", host.domain
    end
  end

  test "answers are cached for minutes, an unknown for one" do
    store = ActiveSupport::Cache::MemoryStore.new
    Rails.stub(:cache, store) do
      DnsHost.lookup("turfmonster.media")
      DnsHost.lookup("turfmonster.media")
      assert_equal %w[turfmonster.media], @queries, "the second read comes from the cache"

      travel DnsHost::CACHE_TTL + 1.second do
        DnsHost.lookup("turfmonster.media")
      end
      assert_equal 2, @queries.size, "it re-reads once the cache expires"

      DnsHost.lookup("nowhere.example")
      travel DnsHost::UNKNOWN_TTL + 1.second do
        DnsHost.lookup("nowhere.example")
      end
      assert_equal 4, @queries.size, "an unknown is retried after a minute"
    end
  end

  test "a cache outage still answers" do
    broken = Object.new
    def broken.read(*) = raise(IOError, "cache down")
    Rails.stub(:cache, broken) do
      assert DnsHost.lookup("turfmonster.media").unknown?
    end
  end
end
