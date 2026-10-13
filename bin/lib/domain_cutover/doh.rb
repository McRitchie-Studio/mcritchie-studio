# frozen_string_literal: true

require "uri"

module DomainCutover
  # DNS-over-HTTPS, the only way this command reads DNS.
  #
  # WHY NOT dig OR Resolv. This laptop intercepts ALL port-53 traffic with a
  # non-validating resolver, so a local answer can be a lie: on 2026-10-13 local
  # `dig` showed commercialwelding.llc and mcritchie.industries healthy for the
  # whole SERVFAIL outage (11:52-12:05 MDT) that every validating public resolver
  # saw. DoH rides HTTPS to the resolver itself, so the interception never sees it.
  #
  # Two resolvers, read side by side: Google's and Cloudflare's. A record is
  # "public" when both answer it. `cd: true` sets the checking-disabled bit, which
  # is how a DS still published at the TLD can be read while validation fails.
  class Doh
    RESOLVERS = {
      "google" => "https://dns.google/resolve",
      "cloudflare" => "https://cloudflare-dns.com/dns-query"
    }.freeze

    TYPES = { "A" => 1, "NS" => 2, "CNAME" => 5, "MX" => 15, "TXT" => 16, "AAAA" => 28, "DS" => 43,
              "CAA" => 257 }.freeze
    STATUS = { 0 => "NOERROR", 2 => "SERVFAIL", 3 => "NXDOMAIN", 5 => "REFUSED" }.freeze

    # One resolver's answer: the RCODE and the records whose owner and type match
    # the question (a CNAME chain's other links are dropped).
    Answer = Struct.new(:resolver, :status, :records, keyword_init: true) do
      def ok? = status.zero? || status == 3
      def servfail? = status == 2
      def label = STATUS.fetch(status, "RCODE #{status}")
    end

    def initialize(transport)
      @transport = transport
    end

    def query(resolver, name, type, cd: false)
      params = { "name" => name, "type" => type }
      params["cd"] = "1" if cd
      url = "#{RESOLVERS.fetch(resolver)}?#{URI.encode_www_form(params)}"
      res = @transport.call(:get, url, headers: { "accept" => "application/dns-json" })
      raise Abort, "DoH #{resolver} #{name} #{type}: HTTP #{res.status}" unless res.ok?

      body = res.json
      want = Records.name(name)
      code = TYPES.fetch(type)
      records = Array(body["Answer"]).filter_map do |a|
        next unless a["type"].to_i == code && Records.name(a["name"]) == want

        Records.from_dns(want, type, a["data"])
      end
      Answer.new(resolver: resolver, status: body["Status"].to_i, records: records)
    end

    # Both resolvers' answers to one question.
    def both(name, type, cd: false)
      RESOLVERS.keys.map { |r| query(r, name, type, cd: cd) }
    end

    # Is a DS published for the domain at its TLD? Read with checking disabled so
    # a validation failure cannot hide it.
    def ds_published?(domain)
      both(domain, "DS", cd: true).any? { |a| a.records.any? }
    end
  end
end
