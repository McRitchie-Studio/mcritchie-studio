require "net/http"

module AgentProposals
  # The hub's client for Turf Monster's operator endpoint (turf-monster
  # docs/OPERATOR_API.md): the one path the Turf agent's contest reads and
  # operations take (docs/agents/system/agent-message-loop.md, "Operations").
  # Modeled on DailyAppReport::Fetcher: the app's production URL from the app
  # catalog, a bearer token from the environment, short timeouts, and errors
  # reduced to a short reason that can never carry the token or a body.
  #
  # Its own token (OPERATOR_TOKEN_TURF_MONSTER, the app's TURF_OPERATOR_TOKEN),
  # never the read-only health report's. Unset, every call is NotWired and
  # nothing is sent.
  class TurfOperator
    APP = "turf-monster".freeze
    TOKEN_ENV = "OPERATOR_TOKEN_TURF_MONSTER".freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    SLUG = /\A[a-z0-9][a-z0-9-]{0,99}\z/
    MESSAGE_MAX = 300
    NETWORK_ERRORS = [ SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
                       Net::HTTPBadResponse, Net::ProtocolError ].freeze

    # Could not reach or read the endpoint. The message is a short reason.
    class Error < StandardError; end
    class NotWired < Error; end

    # Turf answered and refused (422): a stable code and Turf's operator copy.
    class Refused < StandardError
      attr_reader :code

      def initialize(code, message)
        @code = code.to_s[0, 60]
        super(message.to_s.gsub(/[[:cntrl:]]/, " ").squish[0, MESSAGE_MAX])
      end
    end

    # `transport` answers [status code, body String] for (verb, URI, JSON body
    # or nil, headers); a test hands one in.
    def initialize(env: ENV, base_url: nil, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT, transport: nil)
      @env = env
      @base_url = base_url
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @transport = transport || method(:http)
    end

    def base_url = (@base_url || AppCatalog.app(APP)&.production_url).to_s.chomp("/")

    def contests(scope: "open", limit: 10)
      request(:get, "/_operator/contests", query: { scope: scope, limit: limit })
    end

    def cancel(slug:, paid_entries:, requested_by:, request_ref:)
      raise Refused.new("bad_slug", "#{slug.to_s[0, 80].inspect} is not a contest slug") unless SLUG.match?(slug.to_s)

      request(:post, "/_operator/contests/#{slug}/cancel",
              body: { paid_entries: paid_entries, requested_by: requested_by, request_ref: request_ref })
    end

    def prepare(week:, weeks:, season:, contest_type:)
      request(:post, "/_operator/contests/prepare",
              body: { week: week, weeks: weeks, season: season, contest_type: contest_type })
    end

    # The app's page for a path the endpoint returned (a Treasury or create link).
    def url_for(path) = "#{base_url}#{path.to_s.start_with?('/') ? path : "/#{path}"}"

    private

    def request(verb, path, query: nil, body: nil)
      token = @env[TOKEN_ENV].to_s.strip
      raise NotWired, "the Turf operator endpoint is not wired here (#{TOKEN_ENV} is unset)" if token.empty?
      raise NotWired, "Turf Monster has no production URL in the app catalog" if base_url.empty?

      uri = URI.parse("#{base_url}#{path}")
      uri.query = URI.encode_www_form(query) if query
      headers = { "Authorization" => "Bearer #{token}", "Accept" => "application/json", "Content-Type" => "application/json" }
      code, raw = @transport.call(verb, uri, body && JSON.generate(body), headers)
      parsed = parse(raw)
      case code.to_i
      when 200 then parsed || raise(Error, "bad JSON")
      when 422 then raise Refused.new(parsed.to_h["error"], parsed.to_h["message"].presence || "refused")
      when 401 then raise Error, "HTTP 401 token mismatch"
      when 404 then raise Error, "HTTP 404 endpoint not deployed or not enabled"
      else raise Error, "HTTP #{code.to_i}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise Error, "timeout"
    rescue *NETWORK_ERRORS => e
      raise Error, e.class.name.demodulize
    rescue URI::InvalidURIError
      raise Error, "bad URL"
    end

    def parse(raw)
      value = JSON.parse(raw.to_s)
      value.is_a?(Hash) ? value : nil
    rescue JSON::ParserError
      nil
    end

    def http(verb, uri, body, headers)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @open_timeout if http.respond_to?(:write_timeout=)
      klass = verb == :post ? Net::HTTP::Post : Net::HTTP::Get
      req = klass.new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body
      response = http.request(req)
      [ response.code.to_i, response.body ]
    end
  end
end
