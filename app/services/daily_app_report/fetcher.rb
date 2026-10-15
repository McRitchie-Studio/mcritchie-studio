require "net/http"

module DailyAppReport
  # Reads one satellite's health over HTTP:
  #   GET <production_url>/_studio/health_report?ending=<iso8601>
  #   Authorization: Bearer <token>
  # Returns the parsed body. Any failure raises Fetcher::Error with a SHORT
  # reason fit for the report line ("timeout", "HTTP 401 token mismatch"); the
  # token never appears in a reason.
  class Fetcher
    Error = Class.new(StandardError)

    PATH = "/_studio/health_report".freeze
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 20
    NETWORK_ERRORS = [ SocketError, SystemCallError, IOError, EOFError, OpenSSL::SSL::SSLError,
                       Net::HTTPBadResponse, Net::ProtocolError ].freeze

    def initialize(open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def self.uri_for(base_url, ending)
      uri = URI.parse("#{base_url.to_s.chomp('/')}#{PATH}")
      uri.query = URI.encode_www_form(ending: ending.iso8601)
      uri
    end

    def fetch(base_url, token:, ending:)
      uri = self.class.uri_for(base_url, ending)
      response = get(uri, token)
      code = response.code.to_i
      case code
      when 200 then parse(response.body)
      when 401 then raise Error, "HTTP 401 token mismatch"
      when 404 then raise Error, "HTTP 404 endpoint not deployed"
      else raise Error, "HTTP #{code}"
      end
    rescue Net::OpenTimeout, Net::ReadTimeout, Timeout::Error
      raise Error, "timeout"
    rescue *NETWORK_ERRORS => e
      raise Error, e.class.name.demodulize
    rescue URI::InvalidURIError
      raise Error, "bad URL"
    end

    private

    def get(uri, token)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout
      http.write_timeout = @open_timeout if http.respond_to?(:write_timeout=)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = "application/json"
      http.request(request)
    end

    def parse(body)
      parsed = JSON.parse(body.to_s)
      raise Error, "bad JSON" unless parsed.is_a?(Hash)

      parsed
    rescue JSON::ParserError
      raise Error, "bad JSON"
    end
  end
end
