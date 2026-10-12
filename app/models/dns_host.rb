require "resolv"

# Who serves a domain's DNS today, read live from its nameservers: Cloudflare,
# Squarespace, name.com, another host, or "unknown" when the lookup fails.
#
# /stack draws it per client, so a CTO client still on Squarespace reads as
# "migration pending" and visibly flips to Cloudflare the moment its
# nameservers move (domain-dns § Cloudflare DNS — CTO and above).
#
# The page must never wait long on, or fail because of, DNS: each query times
# out in about a second, every failure reads as "unknown", and answers are
# cached for minutes (an unknown for one minute, so a hiccup clears itself).
#
# The resolver is injectable: `DnsHost.resolver = ->(name) { [ns hostnames] }`.
# The test suite arms DNS_HOST_NO_LIVE_CALLS (test/test_helper.rb), under which
# the default resolver answers nothing, so no test can reach real DNS: a test
# that wants a host stubs the resolver.
class DnsHost
  NO_LIVE_CALLS_ENV = "DNS_HOST_NO_LIVE_CALLS".freeze

  # key => [label, nameserver pattern]. Squarespace took over Google Domains, so
  # its legacy googledomains.com nameservers are Squarespace's too.
  PROVIDERS = {
    "cloudflare" => [ "Cloudflare", /(\A|\.)ns\.cloudflare\.com\z/ ],
    "squarespace" => [ "Squarespace", /(\A|\.)(squarespacedns|googledomains)\.com\z/ ],
    "name_com" => [ "name.com", /(\A|\.)name\.com\z/ ]
  }.freeze
  OTHER = "other".freeze
  UNKNOWN = "unknown".freeze

  QUERY_TIMEOUT = 1 # seconds, per query
  CACHE_TTL = 10.minutes
  UNKNOWN_TTL = 1.minute

  Result = Data.define(:domain, :key, :nameservers) do
    def label
      return "Unknown" if unknown?
      return DnsHost::PROVIDERS.dig(key, 0) if DnsHost::PROVIDERS.key?(key)

      # Another host: name it by its nameserver's own domain (ns1.example.net → example.net).
      nameservers.first.to_s.split(".").last(2).join(".").presence || "Other"
    end

    def cloudflare? = key == "cloudflare"
    def unknown? = key == DnsHost::UNKNOWN
  end

  class << self
    attr_writer :resolver

    # A callable: name => the NS hostnames that name has (empty when none).
    def resolver = @resolver || method(:live_nameservers)

    def reset_resolver! = @resolver = nil

    # The domain whose DNS host matters for a URL or bare host: lowercased,
    # without scheme, path, port or a leading "www.". nil for a blank.
    def domain_for(url_or_host)
      text = url_or_host.to_s.strip.downcase
      return nil if text.empty?

      host = text.include?("://") ? URI.parse(text).host : text.split("/").first.split(":").first
      host&.delete_prefix("www.").presence
    rescue URI::InvalidURIError
      nil
    end

    # The Result for one domain, cached. Never raises.
    def lookup(domain)
      domain = domain_for(domain)
      return Result.new(domain: nil, key: UNKNOWN, nameservers: []) if domain.nil?

      cache_key = "dns_host/v1/#{domain}"
      cached = Rails.cache.read(cache_key)
      return cached if cached

      result = resolve(domain)
      Rails.cache.write(cache_key, result, expires_in: result.unknown? ? UNKNOWN_TTL : CACHE_TTL)
      result
    rescue StandardError => e
      # A cache outage is no reason to 500 the page either.
      Rails.logger.info("[DnsHost] #{domain}: #{e.class}: #{e.message}")
      result || Result.new(domain: domain, key: UNKNOWN, nameservers: [])
    end

    # domain => Result for many domains at once, looked up side by side so a
    # page of clients costs one timeout at worst, not one per client.
    def lookup_many(domains)
      domains = domains.filter_map { |d| domain_for(d) }.uniq
      threads = domains.map { |domain| [ domain, Thread.new { lookup(domain) } ] }
      # Joining under permit_concurrent_loads keeps a dev-mode autoload in a
      # lookup thread from deadlocking against this request's load lock.
      ActiveSupport::Dependencies.interlock.permit_concurrent_loads do
        threads.to_h { |domain, thread| [ domain, thread.value ] }
      end
    end

    # The provider key for a set of nameserver hostnames.
    def classify(nameservers)
      names = Array(nameservers).map { |ns| ns.to_s.downcase.delete_suffix(".") }.reject(&:empty?)
      return UNKNOWN if names.empty?

      PROVIDERS.each { |key, (_, pattern)| return key if names.any? { |ns| ns.match?(pattern) } }
      OTHER
    end

    private

    # Walk up from the domain to its registrable parent: a subdomain without its
    # own delegation (www., app.) answers no NS, its zone apex does.
    def resolve(domain)
      labels = domain.split(".")
      (0..(labels.size - 2)).each do |drop|
        name = labels.drop(drop).join(".")
        nameservers = Array(resolver.call(name)).map { |ns| ns.to_s.downcase.delete_suffix(".") }
        next if nameservers.empty?

        return Result.new(domain: name, key: classify(nameservers), nameservers: nameservers.sort.freeze)
      end
      Result.new(domain: domain, key: UNKNOWN, nameservers: [])
    rescue StandardError, Timeout::Error => e
      Rails.logger.info("[DnsHost] #{domain}: #{e.class}: #{e.message}")
      Result.new(domain: domain, key: UNKNOWN, nameservers: [])
    end

    def live_nameservers(name)
      return [] if ENV[NO_LIVE_CALLS_ENV].present?

      Resolv::DNS.open do |dns|
        dns.timeouts = QUERY_TIMEOUT
        dns.getresources(name, Resolv::DNS::Resource::IN::NS).map { |ns| ns.name.to_s }
      end
    end
  end
end
