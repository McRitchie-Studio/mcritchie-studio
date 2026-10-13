# frozen_string_literal: true

module DomainCutover
  # The registry's own record of a domain, over RDAP (rdap.org redirects to the
  # TLD's server): who the registrar is, which nameservers the registry hands
  # out, and whether a DS is published (secureDNS.delegationSigned). This is the
  # registry's view, so it moves minutes after a registrar save and long before
  # resolver caches do.
  class Rdap
    BASE = "https://rdap.org/domain/"

    # Registrar key => pattern on the RDAP registrar name. Squarespace bought
    # Google Domains, so a Google registrar row is Squarespace's console now.
    REGISTRARS = {
      "squarespace" => /squarespace|google/i,
      "godaddy" => /godaddy|wild west domains/i,
      "namecheap" => /namecheap/i,
      "porkbun" => /porkbun/i,
      "cloudflare" => /cloudflare/i
    }.freeze

    Info = Struct.new(:registrar, :registrar_key, :nameservers, :delegation_signed, keyword_init: true)

    def initialize(transport)
      @transport = transport
    end

    def lookup(domain)
      res = @transport.call(:get, "#{BASE}#{Records.name(domain)}", headers: { "accept" => "application/rdap+json" })
      raise Abort, "RDAP #{domain}: HTTP #{res.status}" unless res.ok?

      parse(res.json)
    end

    def parse(body)
      registrar = registrar_name(body)
      Info.new(
        registrar: registrar,
        registrar_key: self.class.registrar_key(registrar),
        nameservers: Array(body["nameservers"]).map { |ns| Records.name(ns["ldhName"]) }.reject(&:empty?).sort,
        delegation_signed: body.dig("secureDNS", "delegationSigned") == true
      )
    end

    def self.registrar_key(name)
      REGISTRARS.each { |key, pattern| return key if name.to_s.match?(pattern) }
      "other"
    end

    private

    def registrar_name(body)
      entity = Array(body["entities"]).find { |e| Array(e["roles"]).include?("registrar") }
      return nil unless entity

      fn = Array(entity.dig("vcardArray", 1)).find { |prop| prop[0] == "fn" }
      fn ? fn[3].to_s : entity["handle"].to_s
    end
  end
end
