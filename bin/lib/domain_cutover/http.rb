# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

module DomainCutover
  # Raised for every refusal and every failed call. The message is printed as-is,
  # so it never carries a token: credentials ride in headers only, and #redact
  # scrubs any echo of them from an error body.
  class Abort < StandardError; end

  Response = Struct.new(:status, :body, keyword_init: true) do
    def ok? = status.between?(200, 299)

    def json
      body.to_s.empty? ? {} : JSON.parse(body)
    rescue JSON::ParserError
      {}
    end
  end

  # The one seam every network read and write passes through. Tests inject a fake
  # with the same #call; nothing in this library opens a socket any other way, and
  # in particular nothing asks the local resolver a DNS question: DNS answers come
  # from DoH over HTTPS (see Doh for why).
  class Transport
    MAX_REDIRECTS = 4

    def initialize(open_timeout: 10, read_timeout: 20)
      @open_timeout = open_timeout
      @read_timeout = read_timeout
    end

    def call(verb, url, headers: {}, body: nil)
      uri = URI(url)
      MAX_REDIRECTS.times do
        res = once(verb, uri, headers, body)
        # rdap.org answers with a redirect to the registry's own RDAP server.
        if verb == :get && res.is_a?(Net::HTTPRedirection) && res["location"]
          uri = URI.join(uri.to_s, res["location"])
          next
        end
        return Response.new(status: res.code.to_i, body: res.body.to_s)
      end
      raise Abort, "too many redirects reading #{uri.host}"
    end

    private

    def once(verb, uri, headers, body)
      klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put,
                patch: Net::HTTP::Patch, delete: Net::HTTP::Delete }.fetch(verb)
      req = klass.new(uri)
      headers.each { |k, v| req[k] = v }
      req.body = body if body
      Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                          open_timeout: @open_timeout, read_timeout: @read_timeout) do |http|
        http.request(req)
      end
    rescue SocketError, Timeout::Error, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Abort, "#{uri.host}: #{e.class}: #{e.message}"
    end
  end

  # A write the runner will make: which API, the verb, the path, the JSON body and
  # one line of why. Built by the API clients, performed (or, under --dry-run,
  # only printed) by the runner, so every write has one printable shape.
  Write = Struct.new(:api, :verb, :path, :body, :why, keyword_init: true) do
    def to_s
      line = "#{api.upcase} #{verb.to_s.upcase} #{path}"
      line += " #{JSON.generate(body)}" if body
      "#{line}  # #{why}"
    end
  end

  module_function

  # Replace every secret's text with [REDACTED] in a message bound for output.
  def redact(text, secrets)
    secrets.compact.reject { |s| s.to_s.length < 6 }.reduce(text.to_s) { |t, s| t.gsub(s, "[REDACTED]") }
  end
end
