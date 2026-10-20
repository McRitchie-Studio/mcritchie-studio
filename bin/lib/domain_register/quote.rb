# frozen_string_literal: true

require "bigdecimal"

module DomainRegister
  # Why a domain-check row is not registrable, keyed by its `reason`.
  REASONS = {
    "domain_unavailable" => "already registered by someone",
    "domain_premium" => "a premium domain, which Cloudflare's API does not register",
    "extension_not_supported_via_api" => "Cloudflare sells this extension, but not through the API yet: " \
                                         "buy it in the dashboard",
    "extension_not_supported" => "Cloudflare Registrar does not sell this extension: use Squarespace " \
                                 "(the SOP's manual path)",
    "extension_disallows_registration" => "the registry does not allow new registrations of this extension"
  }.freeze

  # One row of POST /registrar/domain-check, read into plain terms:
  #
  #   { "name": "acmecorp.dev", "registrable": true, "tier": "standard",
  #     "pricing": { "currency": "USD", "registration_cost": "10.11", "renewal_cost": "10.11" } }
  #   { "name": "acme.ly", "registrable": false, "reason": "extension_not_supported_via_api" }
  #
  # Prices arrive as strings and stay exact (BigDecimal), so "10.1" and "10.10"
  # are equal and nothing ever rounds through a float.
  Quote = Struct.new(:name, :registrable, :tier, :reason, :currency, :registration, :renewal, keyword_init: true) do
    def self.from_api(row)
      pricing = row["pricing"] || {}
      new(name: row["name"].to_s.downcase, registrable: row["registrable"] == true,
          tier: row["tier"], reason: row["reason"], currency: pricing["currency"],
          registration: money(pricing["registration_cost"]), renewal: money(pricing["renewal_cost"]))
    end

    def self.money(text)
      return nil if text.nil? || text.to_s.strip.empty?

      BigDecimal(text.to_s)
    rescue ArgumentError
      nil
    end

    # Exact to the cent, never through a float: 10.1 -> "10.10".
    def self.format(amount)
      return "?" if amount.nil?

      whole, cents = amount.round(2).to_s("F").split(".")
      "#{whole}.#{cents.to_s.ljust(2, '0')}"
    end

    def premium? = tier == "premium" || reason == "domain_premium"
    def available? = registrable && !premium?

    def reason_text
      return nil if reason.nil?

      DomainRegister::REASONS.fetch(reason, reason)
    end

    def price_line
      return "no price quoted" if registration.nil?

      "#{currency} #{Quote.format(registration)} to register (1 year), #{currency} #{Quote.format(renewal)} a year to renew"
    end

    def to_s
      status = if available? then "AVAILABLE"
               elsif premium? then "PREMIUM"
               elsif registrable then "REGISTRABLE"
               else "NOT AVAILABLE"
               end
      line = "#{name}  #{status}"
      line += "  #{price_line}" unless registration.nil?
      line += "  (#{reason}: #{reason_text})" if reason
      line
    end
  end
end
