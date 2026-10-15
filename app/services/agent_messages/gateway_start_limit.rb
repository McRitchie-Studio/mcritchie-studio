require "net/http"

module AgentMessages
  # Discord's own count of the session starts (IDENTIFYs) the bot token has
  # left: `session_start_limit` from GET /gateway/bot. The listener reads it
  # before every IDENTIFY and waits out `reset_after` when `remaining` is low,
  # on top of our own GatewayIdentifyBudget. It also sees starts we cannot: the
  # same token used from anywhere else.
  #
  # The token goes in the Authorization header only and is never logged. The
  # `transport` seam matches DiscordBot's: (method, url, headers, body) →
  # [status, body_string]. No test reaches Discord.
  class GatewayStartLimit
    URL = "#{DiscordBot::API}/gateway/bot".freeze

    Error = Class.new(StandardError)
    # remaining: starts left; reset_after: seconds until Discord refills them.
    Limit = Struct.new(:total, :remaining, :reset_after, keyword_init: true)

    def initialize(token:, transport: nil)
      raise ArgumentError, "a bot token is required" if token.to_s.strip.empty?

      @token = token
      @transport = transport || method(:net_http)
    end

    def call
      headers = { "Authorization" => "Bot #{@token}", "User-Agent" => "McRitchieStudio (https://mcritchie.studio, 1)" }
      status, body = @transport.call(:get, URL, headers, nil)
      raise Error, "GET /gateway/bot answered HTTP #{status.to_i}" unless status.to_i.between?(200, 299)

      limit = JSON.parse(body.to_s)["session_start_limit"]
      raise Error, "GET /gateway/bot carried no session_start_limit" unless limit.is_a?(Hash) && limit.key?("remaining")

      Limit.new(total: limit["total"].to_i, remaining: limit["remaining"].to_i,
                reset_after: limit["reset_after"].to_f / 1000.0)
    rescue JSON::ParserError
      raise Error, "GET /gateway/bot answered a body that is not JSON"
    end

    private

    def net_http(_method, url, headers, _body)
      uri = URI(url)
      req = Net::HTTP::Get.new(uri)
      headers.each { |k, v| req[k] = v }
      res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) { |http| http.request(req) }
      [ res.code.to_i, res.body.to_s ]
    rescue SocketError, SystemCallError, Timeout::Error, IOError, OpenSSL::SSL::SSLError => e
      raise Error, "Discord unreachable: #{e.class}"
    end
  end
end
