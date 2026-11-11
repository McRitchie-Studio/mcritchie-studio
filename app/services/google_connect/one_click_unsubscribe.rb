require "ipaddr"
require "net/http"
require "socket"
require "uri"

module GoogleConnect
  # RFC 8058 one-click unsubscribe, for GmailEditor#unsubscribe
  # (/tasks/gmail-one-click-unsubscribe). It reads a message's List-Unsubscribe
  # and List-Unsubscribe-Post headers, says which kind of unsubscribe the sender
  # offers, and for a one-click sender sends the one POST the RFC defines.
  #
  # The URL comes from a stranger's email, so the POST is fenced:
  # - https only; a URL with a user or password in it is refused;
  # - the host must resolve, and EVERY address it resolves to must be public:
  #   no private, loopback, link-local (cloud metadata), CGNAT, multicast or
  #   unspecified address (the SSRF guard). The connection goes to the address
  #   that was checked, so a second DNS answer cannot swap it;
  # - no redirect is followed (a 3xx is a failure);
  # - 5s to open, 10s to read;
  # - no cookie and no Authorization header. It never sees the Gmail token:
  #   #post takes no token at all.
  # It never sends mail and never acts on a mailto: URI.
  class OneClickUnsubscribe
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    BODY = "List-Unsubscribe=One-Click".freeze
    KINDS = %w[one-click web-page email-only none].freeze

    # Every address range a POST may never reach.
    BLOCKED = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/4 240.0.0.0/4
      ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 64:ff9b::/96
    ].map { IPAddr.new(_1) }.freeze

    Outcome = Struct.new(:ok, :status, :error, keyword_init: true)
    Refused = Class.new(StandardError)

    class << self
      # Stand-ins for tests: http is (url, ip, body) -> [status, detail];
      # resolver is (host) -> [ip strings]. nil means the network.
      attr_accessor :http, :resolver

      # "one-click", "web-page", "email-only" or "none" for a message's two headers.
      def kind(list_unsubscribe, list_unsubscribe_post)
        uris = uris(list_unsubscribe)
        return "one-click" if one_click_post?(list_unsubscribe_post) && https_uri(list_unsubscribe)
        return "web-page" if uris.any? { _1.match?(%r{\Ahttps?://}i) }
        return "email-only" if uris.any? { _1.match?(/\Amailto:/i) }

        "none"
      end

      # The first https URI in a List-Unsubscribe header, or nil.
      def https_uri(list_unsubscribe) = uris(list_unsubscribe).find { _1.match?(%r{\Ahttps://}i) }

      # Each <...> entry of a List-Unsubscribe header, in order (RFC 2369).
      def uris(header) = header.to_s.scan(/<\s*([^>]+?)\s*>/).flatten

      def one_click_post?(header) = header.to_s.match?(/\bList-Unsubscribe\s*=\s*One-Click\b/i)

      # Sends the one-click POST to `url`. Never raises: refusals and network
      # errors come back as a failed Outcome with what went wrong.
      def post(url) = new.post(url)
    end

    def post(url)
      uri = checked_uri(url)
      ip = public_address(uri.host)
      status, = send_post(uri, ip)
      return Outcome.new(ok: true, status:) if (200..299).cover?(status)

      error = (300..399).cover?(status) ? "answered #{status}; redirects are not followed" : "answered #{status}"
      Outcome.new(ok: false, status:, error:)
    rescue Refused => e
      Outcome.new(ok: false, error: "refused: #{e.message}")
    rescue *OAuthClient::NETWORK_ERRORS, Net::WriteTimeout, IOError => e
      Outcome.new(ok: false, error: "could not be reached: #{e.class}")
    end

    # The request the network path sends: the RFC's form body and a content
    # type, nothing else of ours (no cookie, no Authorization).
    def build_request(uri)
      request = Net::HTTP::Post.new(uri, "Content-Type" => "application/x-www-form-urlencoded")
      request.body = BODY
      request
    end

    private

    def checked_uri(url)
      uri = URI.parse(url.to_s.strip)
      raise Refused, "not an https URL" unless uri.is_a?(URI::HTTPS) && uri.host.present?
      raise Refused, "a URL with a user or password" if uri.userinfo

      uri
    rescue URI::InvalidURIError
      raise Refused, "not a valid URL"
    end

    # The first address of `host`, once every address it resolves to is public.
    def public_address(host)
      addresses = resolve(host.delete_prefix("[").delete_suffix("]"))
      raise Refused, "#{host} does not resolve" if addresses.empty?

      addresses.each do |address|
        ip = IPAddr.new(address)
        ip = ip.native if ip.ipv6? && ip.ipv4_mapped?
        raise Refused, "#{host} resolves to a private address" if BLOCKED.any? { _1.include?(ip) }
      end
      addresses.first
    rescue IPAddr::InvalidAddressError
      raise Refused, "#{host} resolves to an address that cannot be read"
    end

    def resolve(host)
      return Array(self.class.resolver.call(host)) if self.class.resolver

      Addrinfo.getaddrinfo(host, 443, nil, :STREAM).map(&:ip_address).uniq
    rescue SocketError
      []
    end

    def send_post(uri, ip)
      return self.class.http.call(uri.to_s, ip, BODY) if self.class.http

      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = ip # connect to the checked address; TLS still verifies the host name
      http.use_ssl = true
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.write_timeout = READ_TIMEOUT
      response = http.start { _1.request(build_request(uri)) }
      [ response.code.to_i, nil ]
    end
  end
end
